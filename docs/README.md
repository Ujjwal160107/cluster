# `vps` cluster docs

Living operational documentation for the `vps` k3s cluster (Hetzner DE). It began as one stage (S1)
of an architecture programme (S0–S13) whose plan is kept in the private archive and is **not**
part of the published tree, so everything here stands on its own. Status as of 2026-09-27: only
**S0** (safety net) had run. Everything below marked "target" is planned, not yet true of the live
cluster — see [`../changelog/2026-09.md`](../changelog/2026-09.md) for exactly what has executed.

## Never delete casually

This cluster holds real data. Automated backups **do** exist as of 2026-09-28 (S4: restic every
30 min for class A, daily for class C, etcd every 12 h — see [`backups.md`](backups.md)), and as of
2026-09-29 the hourly offsite leg copies every tag into **Cloudflare R2** (`vps-backups`, DR-001), so
there *is* now a second copy off the machine. Read the caveat before trusting them with a deletion:
the node-local repository is on the **root disk**, so losing the server loses that copy — R2 is what
survives it. Treat every one of these as irreversible:

- **PersistentVolumeClaims / PersistentVolumes** — `kubectl delete pvc|pv` on a dynamic volume
  whose PV is `reclaimPolicy: Delete` destroys the underlying data immediately. Nine PVs were
  patched to `Retain` in S0 (see the changelog) specifically to make this recoverable; don't
  assume every PV is safe — check first: `kubectl get pv -o custom-columns=N:.metadata.name,R:.spec.persistentVolumeReclaimPolicy`.
- **Hetzner volumes** — deleting a volume from the Hetzner console/API is immediate and
  unrecoverable; no snapshot exists per-volume today.
- **The Hetzner server or its primary IPs** — deleting the server is guarded
  (`delete_protection` + `rebuild_protection`) and both primary IPs have `auto_delete=false` plus
  delete protection, so the addresses and DNS survive a rebuild. Verified live 2026-09-28. Deleting an
  *IP* is still the one action that forces re-pointing every DNS record — and Terraform's
  `prevent_destroy` is the guard against doing it by accident.
- **Git history** — a history rewrite is planned (S5, after secret rotation) but only with
  explicit per-step owner confirmation; never `git push --force` outside that documented, approved
  procedure.
- **restic / etcd snapshots** — the automated recovery path (see [`backups.md`](backups.md)).
  `restic forget --prune` outside the scripted weekly retention, or deleting `/var/backups/restic`,
  removes recovery points you cannot get back. The node-local repository is also the first thing lost
  with the server; the hourly R2 offsite copy (DR-001) is the durable one, and the S0 bundle and the
  workstation mirror (`scripts/pull-backups.sh`, a daily systemd timer on the workstation since
  2026-09-29 — DR-003) are further independent copies.
- **Any Secret** — never delete or overwrite a Kubernetes Secret, `.env` file, or credential
  without first confirming a verified-restorable backup and understanding every consumer of that
  credential (rotating a DB password without updating the app's own secret breaks the app).
- **Never**, without explicit confirmation: format a disk, reinstall k3s over existing data, prune
  ArgoCD blindly (enable `prune: true` only after ownership is verified), destroy Terraform-managed
  infrastructure, migrate persistent data without a validated backup, or assume any backup is good
  without a restore test.

If in doubt: stop, read [`disaster-recovery.md`](disaster-recovery.md) and the relevant runbook
under [`runbooks/`](runbooks/), and confirm with the owner before running anything destructive.

## Index

| Doc | Covers |
|---|---|
| [`architecture.md`](architecture.md) | Current-state and target-state cluster architecture, ownership model |
| [`adr/`](adr/README.md) | Architecture Decision Records — *why* the cluster is built this way: status, context, the alternatives rejected and the consequences that follow, including the unpleasant ones (nine records, appended to as decisions are made) |
| [`inventory.md`](inventory.md) | Machine sheet: server/IP/volume IDs, k3s version/flags, contacts |
| [`storage.md`](storage.md) | Per-dataset storage inventory, criticality, target storage strategy |
| [`backups.md`](backups.md) | Backup architecture: what exists today vs. the target S4 system |
| [`disaster-recovery.md`](disaster-recovery.md) | What survives today, target DR scenarios (RPO/RTO), how to recover right now |
| [`ports.md`](ports.md) | Human-readable port registry (source: [`../inventory/ports.yaml`](../inventory/ports.yaml)) |
| [`networking.md`](networking.md) | Firewall layers, Tailscale, Cloudflare — current and target |
| [`secrets.md`](secrets.md) | Secrets architecture: plaintext today, target SOPS+age design |
| [`certificates.md`](certificates.md) | TLS architecture: current mid-migration state, target Origin CA design |
| [`monitoring.md`](monitoring.md) | Monitoring stack, the Grafana credential-loop root cause and fix |
| [`maintenance.md`](maintenance.md) | Routine tasks, disk hygiene, per-layer ownership rules |
| [`upgrade-policy.md`](upgrade-policy.md) | Target upgrade cadence for OS/k3s/ArgoCD/charts |
| [`runbooks/restore-postgres.md`](runbooks/restore-postgres.md) | Restore any in-cluster Postgres DB from a dump |
| [`runbooks/restore-mongo.md`](runbooks/restore-mongo.md) | Restore rankstack's Mongo data |
| [`runbooks/restore-minio.md`](runbooks/restore-minio.md) | Restore MinIO/file-based PVC data |
| [`runbooks/recover-k3s.md`](runbooks/recover-k3s.md) | Restore k3s/etcd from a snapshot |
| [`runbooks/recover-vm.md`](runbooks/recover-vm.md) | Full VM loss recovery |
| [`runbooks/rotate-secrets.md`](runbooks/rotate-secrets.md) | Target credential rotation procedure (S5) |
| [`runbooks/rotate-certificates.md`](runbooks/rotate-certificates.md) | Target certificate rotation procedure (S7) |
| [`runbooks/add-port.md`](runbooks/add-port.md) | Onboarding a new externally-reachable port (usable today) |

## Related

- the architecture review (S0–S13) — the programme's own plan; kept in the private archive, not
  part of the published tree
- [`../changelog/`](../changelog/) — forensic timeline of every change, git-tracked and break-glass
- [`../AGENTS.md`](../AGENTS.md) — repo conventions for anyone (human or agent) editing `k8s/`
- [`../.claude/CLAUDE.md`](../.claude/CLAUDE.md) — hard rules for cluster-affecting changes
