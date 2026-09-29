# 0005. Authoritative data on a separate volume at `/srv/data`, via static retained PVs

- **Status:** Accepted (partially implemented — see the consequences)
- **Date:** 2026-09-28

## Context

Most data on this cluster is disposable: caches, a demo app's sqlite file, an index that can be rebuilt.
A few datasets are not: a tenant's Postgres holding student data, a PostGIS database, and a MinIO bucket
of uploaded files. Those need to survive a mistake, a bad migration, and — as far as possible — the loss
of the node.

The cluster ran on dynamic `local-path` PVs, which means the data sat on the root disk alongside the OS,
container images, container logs and the metrics TSDB. Every dynamic PV also had
`persistentVolumeReclaimPolicy: Delete`, so deleting a PVC destroyed its data (`ArgoCD` pruning one
would have too). And two StorageClasses both carried the "default" annotation, so a PVC that merely
omitted `storageClassName` was placed by coin flip — which is exactly how one app ended up bound to a
billed Hetzner volume that was later deleted, leaving it unable to start for weeks.

## Decision

**Authoritative data lives on one dedicated Hetzner volume mounted at `/srv/data`, exposed to the cluster
as static `hostPath` PVs with `Retain`. Disposable data may use dynamic provisioning.**

- The volume (`vps-data`, 20 GB) is declared in Terraform with `delete_protection = true`, attached with
  `automount = false`, and mounted by the host's Ansible `data_volume` role through
  `/dev/disk/by-id/…` with `nofail` — the role asserts the device id and **refuses to run `mkfs`**,
  because formatting an already-populated volume is the one unrecoverable mistake available here.
- Each dataset gets its own static PV: `hostPath` on `/srv/data/<dataset>`, `Retain`,
  `storageClassName: ""`, and `volumeMode: Filesystem`. The matching PVC binds statically via an explicit
  `volumeName`. Authoritative PVs are declared in git, so a rebuild re-creates them.
- Authoritative PVs carry `argocd.argoproj.io/sync-options: Delete=false,Prune=false`, so a GitOps
  mistake cannot delete them — removing the file from git leaves the volume alone.
- **`local-path` is for disposable data only**, and PVs that need a specific class must name it
  explicitly rather than relying on a default. There is now exactly one default class.

## Alternatives rejected

- **Everything on Hetzner CSI (`hcloud-volumes`) with dynamic provisioning.** Dynamic PVs default to
  reclaim `Delete`, are coupled to the CSI driver and its Hetzner API token *inside* the cluster, and
  that token is powerful enough to delete every volume and the server — so a cluster compromise becomes
  a data-loss event. It also cannot express "this directory is special, never delete it".
- **Everything on `local-path`.** Simplest, but it puts authoritative data on the root disk, where a full
  disk or a reinstall takes it, and where container image garbage collection runs.
- **A network filesystem (NFS or a cloud file service).** A new dependency, new credentials and a new
  failure mode, for a single-node cluster with local block storage available.

## Consequences

- Losing the node does not lose the data: the volume and its `Delete` protection are separate resources.
  Rebuild still requires re-attaching the volume, re-mounting it, and letting git re-create the PVs.
- **Backups remain mandatory.** A volume in the same Hetzner account is not a backup — it does not
  survive credential compromise or account loss (see ADR 0006).
- Static binding is deliberate and mildly inconvenient: a PVC without the matching `volumeName` and
  `storageClassName: ""` will not bind, and a PV that has already been claimed cannot be re-used.
- **A StorageClass cannot be changed in place.** A PVC's `storageClassName` and `volumeName` are
  immutable once bound, so moving a dataset between classes is a delete-and-recreate with a verified
  backup first. That is a real constraint, learned from the smart-home incident, and the reason a
  storage change is treated as a data-moving operation rather than a manifest edit.
- **Partially implemented, stated plainly:** the volume exists and is mounted, and the tenant and
  PostGIS datasets live on it, but the two legacy Hetzner CSI volumes are still present and one
  StorageClass (`hcloud-volumes`) still exists for historical reasons. Closing that is tracked work
  (`CLEAN-004`), not an assumption.

## Evidence

`terraform/storage.tf` in the `cluster` checkout (`cluster/terraform/storage.tf`),
`ansible/roles/data_volume/`, `docs/storage.md` (the per-dataset table),
`k8s/platform/storage/persistentvolumes.yaml`, and the storage entries in `changelog/2026-09.md`.
