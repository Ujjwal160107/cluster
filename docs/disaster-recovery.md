# Disaster recovery

Two things exist to recover from: the **automated restic backup on the node** (S4, live since
2026-09-28) and the **one-off S0 bundle** as an independent point-in-time record. The node-local
repository is copied hourly to **Cloudflare R2** (`vps-backups`, DR-001), so the offsite leg is no
longer pending.

Full background: the architecture review (private, not published) §6 (then-current assessment) and
§12 (target scenario table). The system itself, including what has
been verified, is in [`backups.md`](backups.md).

## What to reach for, in order

**1. The automated restic repository — `/var/backups/restic` on the node.**

- Class A every 30 min (`vcap-staging` Postgres+MinIO, `meghmitra` Postgres); class C daily
  (`vcap-dev`, `bitvault`, `rankstack`, `grafana`); every 12 h an etcd snapshot **plus** the k3s
  server token, tls and `/etc/rancher/k3s`; and the exported MinIO image tarball, which can no longer
  be pulled from any registry.
- Password: `restic_password` in `ansible/group_vars/vps/secrets.sops.yaml`. On the node it is
  already in `/etc/vps-backup/env` (mode 0600), which is what the systemd units read.
- The repository itself is on the node's root disk; the **hourly `vps-backup-offsite.timer` copies
  every tag** (class A, class C, `etcd`, image tarballs) into the independent **Cloudflare R2**
  repository `vps-backups` with `restic copy`. R2 is therefore the copy that survives losing the
  VM, and the one `runbooks/recover-vm.md` and `runbooks/recover-k3s.md` restore from. The R2
  coordinates and keys live in the host-local, never-committed `/etc/vps-backup/r2.env`; the backup
  bucket's own S3 token is scoped to `vps-backups` only.

**2. The one-off S0 bundle** — `/root/pre-migration-2026-09/` on the node, plus a checksum-verified
copy on the operator workstation (`SHA256SUMS.txt`). It holds Postgres dumps, an etcd snapshot, the
k3s server secrets, per-volume tarballs, Grafana's data and the MinIO image. Independent of
everything else, and it only gets staler.

**3. The optional workstation mirror** — `scripts/pull-backups.sh` copies class-A snapshots to the
operator's machine and verifies them (`restic check`). This is the only copy that survives losing
*both* Hetzner and Cloudflare.

## Measured RPO and RTO

| | Value | Basis |
|---|---|---|
| RPO, class A | **≤ 30 min** | the class-A timer runs `OnUnitActiveSec=30min`. Was 15 min until
2026-09-28, when it was lengthened to halve R2 Class A operation counts (the free tier is 1M/month
and restic lists the repository on every run); whether it returns to 15 min depends on the measured
counts — see `changelog/2026-09.md` |
| RPO, class C | ≤ 24 h | daily timer |
| RTO, class-A database restore | **< 5 minutes** | measured in the monthly restore drill, which restores the newest snapshot into throwaway pods, imports both databases and compares row counts against live — they match exactly (1 385 and 48 672 rows) |
| RTO, VM loss | ~2 h target | Terraform → Ansible → etcd restore. **Never exercised end-to-end**; that is what the S12 drill on a temporary VM is for |
| Class C restore | not tested | never restore-tested (owner accepted the loss); the dumps are produced and validated as archives only |

## What survives what

| Scenario | What survives | Mechanism |
|---|---|---|
| Accidental PVC delete / ArgoCD prune | the data | nine dynamic PVs are `Retain` (S0) → rebind the Retained PV |
| Bad migration, dropped table/row | ≤ 30 min of class-A data | `pg_restore` from restic — [`runbooks/restore-postgres.md`](runbooks/restore-postgres.md) |
| k3s / etcd corruption | ≤ 12 h of cluster state (git holds desired state) | etcd snapshot + matching token/tls from the same restic snapshot — [`runbooks/recover-k3s.md`](runbooks/recover-k3s.md) |
| Root filesystem corruption | `/srv/data` (a separate volume), and the restic repository only if the disk survived | rebuild via Terraform + Ansible. **No Hetzner server backup** — disabled, over budget |
| **VM loss** | `/srv/data` (separate Hetzner volume), **the two primary IPs** (both `auto_delete=false` and delete-protected, so DNS survives) — but **not** the node-local restic repository, which lives on the root disk | Terraform new VM (via `cluster`'s `scripts/tf.sh`) → move the IPs + `vps-data` → Ansible → **etcd restore from R2** or `bootstrap.sh`. The hourly offsite copy in R2 holds the class-A/C, etcd and image sets; the S0 bundle and workstation mirror are further fallbacks — [`runbooks/recover-vm.md`](runbooks/recover-vm.md) |
| `vps-data` volume loss | class-A dumps from restic if the node survived; otherwise the S0 bundle or mirror | [`runbooks/restore-*.md`](runbooks/) |
| Hetzner account / token compromise | data on the volume; **not** the node-local restic repository | rotate the token, rebuild the node, restore the volume |
| Cloudflare account compromise | everything on Hetzner; the R2 backup copy is exposed to the account holder | DNS is the exposure, not backups. R2 holds the offsite restic copy, so a Cloudflare compromise reaches the offsite set too — the bucket-lock rule is the mitigation, and it applies now that R2 is in use |
| Both Hetzner and Cloudflare compromised | whatever the workstation mirror holds (≤ 1 week stale) | `scripts/pull-backups.sh` |

## The honest summary

Class-A data is now protected against the common losses — accidental deletion, a bad migration, logical
corruption — with a **measured** sub-5-minute restore path and a monthly automated drill that proves it
by importing the dumps and comparing row counts. Hardening that is already in place and worth knowing: the server has
`delete_protection` + `rebuild_protection`, both primary IPs are `auto_delete=false` and
delete-protected, and the `vps-data` volume is delete-protected — all verified live on 2026-09-28
(`terraform plan` reports no differences). Losing the machine itself is now covered by the **hourly
offsite copy into Cloudflare R2** (DR-001, live since 2026-09-29): the node-local repository dies
with the server, but R2 holds the same snapshots. The workstation mirror (`scripts/pull-backups.sh`)
remains the only copy that survives a simultaneous Hetzner *and* Cloudflare loss, and still runs only
when someone runs it.

## Related

- [`backups.md`](backups.md) — the backup system, its timers, its metrics, its alerts, and its
  verified tests
- [`storage.md`](storage.md) — per-dataset criticality this page is keyed off
- Runbooks: [`restore-postgres.md`](runbooks/restore-postgres.md),
  [`restore-mongo.md`](runbooks/restore-mongo.md), [`restore-minio.md`](runbooks/restore-minio.md),
  [`recover-k3s.md`](runbooks/recover-k3s.md), [`recover-vm.md`](runbooks/recover-vm.md),
  [`rotate-secrets.md`](runbooks/rotate-secrets.md)
