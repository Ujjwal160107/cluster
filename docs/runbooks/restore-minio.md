# Runbook: restore MinIO / file-based PVC data

Applies to vcap-dev, vcap-staging, bitvault-minio, and hello-kitty's file-backed PersistentVolumes
— all of which store data as plain files on their PV (no MinIO-internal replication/erasure coding
in this single-drive deployment), so a filesystem-level tar/restore is safe and sufficient.

## Source: the automated restic repository (primary), the S0 tars (fallback)

The MinIO data directories are in the class-A/C snapshots — `/srv/data/vcap-staging/minio`,
`/srv/data/vcap-dev/minio`, and bitvault's PVC. Class A is captured every 30 min, so this is the
fresh copy; the S0 tars only get staler.

```bash
ssh vps 'set -a; . /etc/vps-backup/env; set +a; export RESTIC_REPOSITORY=/var/backups/restic
  restic restore latest --tag class-A --target /tmp/restore'
# → /tmp/restore/srv/data/vcap-staging/minio/…
# Restore it onto the mount the way step 3 below does, or copy objects back through the S3 API.
```

⚠️ Skip MinIO's own `.minio.sys/tmp/` (scratch and trash). It churns constantly, so files present at
dump time are routinely gone later; the restore drill excludes it for exactly that reason.

## Restore from an S0-style tar snapshot

```bash
# 1. Find the PV's host path
kubectl get pv <pv-name> -o jsonpath='{.spec.local.path}{.spec.hostPath.path}'
# For CSI volumes (vcap-dev/staging), find the live mount instead:
ssh vps "findmnt -rno TARGET -S /dev/<device> | grep '/mount\$'"

# 2. Scale the workload to 0 to avoid writing over the restore
kubectl scale deploy/<minio-deployment> -n <namespace> --replicas=0

# 3. Clear and restore (⚠️ destructive — confirm the target path is correct first)
ssh vps "rm -rf <pv-host-path>/* && tar -xzf - -C <pv-host-path>" < <tar-file>.tar.gz

# 4. Scale back up
kubectl scale deploy/<minio-deployment> -n <namespace> --replicas=1
```

## Verification

```bash
# From inside the pod, using the mc client if present, or via the app's own S3 calls:
kubectl exec -n <namespace> <minio-pod> -- mc ls local/
# Or check object counts against what the app expects (vcap: `vcap-artifacts`, `vcap-workspace` buckets)
```

Confirm application health afterward (`kubectl get pods -n <namespace>`, app-specific smoke test)
rather than trusting file presence alone — MinIO's own bucket metadata must also be intact for the
server to serve objects correctly.

## ⚠️ MinIO server image availability

The vcap and bitvault MinIO deployments run `quay.io/minio/minio:RELEASE.2025-04-22T22-12-26Z` (or
older pins), which **upstream no longer serves** (`401 Unauthorized` on both `docker.io` and
`quay.io` for this tag and `:latest`). The only working copy today is what's still cached in the
node's containerd, exported during S0 to
`/root/pre-migration-2026-09/minio-RELEASE.2025-04-22.tar` (and the workstation copy) — see the
`## 2026-09-27` entry in [`../../changelog/2026-09.md`](../../changelog/2026-09.md). A ghcr mirror
push was attempted but is currently **blocked** on a missing `write:packages` token scope.

**Do not restart, reschedule, or delete the vcap/bitvault MinIO pods** until either the ghcr
mirror succeeds or you've confirmed the node's containerd image cache still holds this image
(`k3s ctr -n k8s.io images ls | grep minio`) — losing that cached image with no working mirror
means the MinIO server can't start at all, on this node or any replacement.

If you need to restore MinIO onto a *different* node (recovery scenario): import the tarball first
— `k3s ctr -n k8s.io images import minio-RELEASE.2025-04-22.tar` — before scaling the deployment
back up there.

## Tested, and how

The monthly drill **does** restore this data and diff it: it restores the newest class-A snapshot and
checks that every restored object under `/srv/data/vcap-staging/minio` exists in the live directory
(it does not require the reverse, because MinIO keeps writing). Measured 2026-09-28: 50 restored
objects, all present live.

The S0 tars were produced from **live** directories (not checkpointed via a stopped pod), which is
acceptable for this small, mostly-static object data per the architecture review's assessment — and
the restic snapshots have the same property. The file-list diff above is what makes that acceptable in
practice, rather than an assumption.

## The image, precisely

The warning below is about the **containerd cache on a live node** — a restart there still works only
while the cache holds, and a mirror would remove the caveat entirely. A **rebuild** is already covered:
the exported tarball is inside every restic `etcd` snapshot (added 2026-09-28) and in the S0 bundle, so
a replacement node can always import it.
