# Runbook: recover k3s / etcd from a snapshot

Applies when the k3s control plane or embedded etcd is corrupted but the VM/disk itself is intact.
For full VM loss, see [`recover-vm.md`](recover-vm.md) instead.

## Preconditions

- An etcd snapshot exists. As of 2026-09-28 these are automated: `vps-etcd-snapshot.timer` runs
  every 12h on the node (script `/usr/local/sbin/vps-etcd-snapshot.sh`), writing to
  `/var/backups/etcd`, and pushing that same set to the restic repository under `--tag etcd`. Since
  2026-09-29 the hourly `vps-backup-offsite.timer` copies every tag — including `etcd` — to the
  **Cloudflare R2** repository `vps-backups`, so the recovery source is R2 rather than the node,
  which is what makes this usable after a full rebuild too. The node still prunes its own
  `on-demand-*` snapshots after 7 days (P4-07); R2 keeps the restic copies.
- The k3s server token and TLS material from **the same point in time** are also available —
  restoring etcd without matching `/var/lib/rancher/k3s/server/{token,tls/}` leaves node/cert
  identity inconsistent. The automated job captures them **in the same restic snapshot** as the etcd
  dump, so taking one snapshot gives a matched set by construction. The S0 bundle also captured both
  together (`/root/pre-migration-2026-09/etcd/pre-arch-vps-<timestamp>` +
  `/root/pre-migration-2026-09/k3s-server-secrets/`) and remains a valid fallback.
- **The node must be named `vps`.** Every PV in the cluster carries `nodeAffinity: vps`, so a node
  with any other name leaves all of them `Pending` and nothing schedules. This is why the DR drill's
  throwaway server is named `vps-rebuild` only as a *drill* name — it is not a name to reuse for a
  recovery (P4-05). Check with `kubectl get nodes`; rename before restoring if it drifted.
- k3s is stopped on the node.

### Getting the newest matched set

R2 is the authoritative source now (the node-local repository does not survive losing the host). The
repository coordinates and keys are in `/etc/vps-backup/r2.env`, the repository password in
`/etc/vps-backup/env` — both mode 0600 on the node:

```bash
# On the node, as root.
set -a; . /etc/vps-backup/env; . /etc/vps-backup/r2.env; set +a

restic snapshots --tag etcd                       # newest is what you want
restic restore latest --tag etcd --target /var/tmp/etcd-restore
# /var/tmp/etcd-restore/var/backups/etcd/                       <- snapshot file
# /var/tmp/etcd-restore/var/lib/rancher/k3s/server/{token,tls}  <- the matching identity material
```

`r2.env` supplies `RESTIC_REPOSITORY` (the R2 URL) and the S3 keys; `/etc/vps-backup/env` supplies
`RESTIC_PASSWORD`. Sourcing both is required — sourcing only one leaves restic either pointed at the
node-local repository or without a password.

If you must work only from the node without R2 (for example, a control-plane-only incident where the
data you need is still local), substitute the local repository explicitly:

```bash
set -a; . /etc/vps-backup/env; set +a
export RESTIC_REPOSITORY=/var/backups/restic
restic restore latest --tag etcd --target /var/tmp/etcd-restore

# Newest local snapshot without restic, if that is all you need:
ls -t /var/backups/etcd/on-demand-* | head -1
```

## Procedure

```bash
ssh vps
systemctl stop k3s

# If token/tls need restoring too (e.g. after a full server rebuild — see recover-vm.md):
# cp -r <backup>/k3s-server-secrets/tls /var/lib/rancher/k3s/server/
# cp <backup>/k3s-server-secrets/token /var/lib/rancher/k3s/server/

k3s server \
  --cluster-reset \
  --cluster-reset-restore-path=<path-to-snapshot-file>

# k3s exits after the reset; start it normally
systemctl start k3s
```

## Validation

```bash
kubectl get nodes                          # 'vps', Ready — any other name means every PV is Pending
kubectl get applications -n argocd -o wide # ArgoCD apps reconcile back to git state
kubectl get pv | grep -v Bound             # should be empty — nodeAffinity 'vps' must be satisfied
kubectl get pods -A | grep -v Running      # should shrink back to the pre-incident baseline
```

Because git is the desired-state source of truth, ArgoCD's `selfHeal` will reconcile most
Kubernetes objects back to the committed state once the apiserver is back — the etcd snapshot
mainly needs to be recent enough to preserve cluster identity (node registration, CA/cert chain,
Secrets not yet in git per [`../secrets.md`](../secrets.md)) and any live-only objects the review
has flagged as unmanaged (see [`../architecture.md`](../architecture.md)).

## Rollback

If the restore makes things worse: this operation is itself destructive to the current (broken)
etcd state, so there is no rollback beyond having *another* snapshot from before you started. Take
a fresh `k3s etcd-snapshot save` immediately before attempting a restore if the current state has
any residual value.

## When this hasn't been tested

Never exercised end-to-end. `--cluster-reset` is explicitly on the "never run without owner
confirmation" list in the architecture programme's implementation brief — get sign-off before
running this outside of a genuine incident.
