# 0006. Backups run from the host with restic, not from inside the cluster

- **Status:** Accepted, partially implemented — the R2 offsite leg is not running; the workstation mirror that covers the same case is, on a daily timer (see consequences)
- **Date:** 2026-09-28

## Context

Before this, there were no backups at all. The realistic loss scenarios, in order of likelihood, were:
an accidental `kubectl delete pvc` (every dynamic PV was reclaim `Delete`), a bad migration or bad
deployment, etcd corruption, filesystem corruption on `/`, and losing the VM.

The instinct is to run backups as a Kubernetes workload, because that is where the state looks like it
lives. That instinct is wrong for the cases that matter most: a cluster that is broken — bad etcd, a
wedged API server, a CrashLooping database — is exactly when you need the backup, and it is exactly when
an in-cluster CronJob will not run. A backup system that shares a failure domain with the thing it
protects is not a backup system.

## Decision

**Backups are driven from the host by systemd timers, dumping through each application's own tools,
then handed to `restic`.**

- **One script, one registry.** `vps-backup.sh` reads `backup-targets.yaml` (a git-tracked list of
  targets: namespace, workload, engine, and a data path for file targets) and, per target, produces a
  consistent dump first — `pg_dump -Fc` for Postgres, `mongodump --oplog` for the replica set,
  `sqlite3 .backup` for Grafana's database — then restic snapshots the staging directory.
- **Two classes, because the data differs.** Class A (the datasets where an hour of loss is real) runs
  every 30 minutes; class C (rebuildable or low-value) runs daily. Retention follows the class:
  class A `--keep-within 48h --keep-daily 30 --keep-weekly 12 --keep-monthly 12`, class C
  `--keep-daily 7`, and etcd snapshots every 12 hours with `--keep-last 14 --keep-monthly 12`. Pruning
  is a scheduled job of its own, because without it a repository only grows.
- **State Kubernetes does not own is included deliberately:** the monitoring TSDB directories, the k3s
  server token and TLS material, and an explicit `k3s etcd-snapshot save` — the last of which is what
  makes a cluster-state recovery possible without a working cluster.
- **Failures must be visible.** Each run writes a textfile metric that Prometheus collects, and alerting
  fires on backup staleness — because a backup that quietly stopped is indistinguishable from a backup
  that works, right up to the restore.
- **The run is exercised, not assumed.** An automated restore drill restores the class-A datasets into a
  scratch namespace monthly and compares row counts against live; an independent weekly `restic check`
  verifies repository integrity; and a runbook covers the per-dataset restore.
- **The repository password comes from SOPS**, rendered to `/etc/vps-backup/env` by Ansible at deploy
  time, so it is never in a unit file or in git (ADR 0002).
- **A second copy outside both providers** is pulled to a workstation by `scripts/pull-backups.sh`. All
  other copies live with the same two providers, so the "Hetzner and Cloudflare both compromised" case
  needs one that does not.

## Alternatives rejected

- **Velero.** Requires a working cluster to run and restore, and its "backup" of a `Deployment` is a
  manifest that git already holds. It was never actually deployed here — a known-stale reference to it
  in the docs is corrected.
- **CSI volume snapshots.** Provider-coupled (they would not restore off Hetzner), not logically
  consistent for a running database (a crash-consistent copy of a Postgres data directory is a coin
  flip), and there is no offsite leg.
- **Replacing this with a database operator that backs itself up.** Per-database, so it would need a
  different restore procedure per engine, and it still shares the cluster's failure domain.
- **Running restic as an in-cluster CronJob.** Fails precisely when needed, and requires the repository
  credential to live in the cluster it is protecting.

## Consequences

- **The backup path has its own failure modes**, and they are silent unless monitored: a wrong path in
  the targets registry makes restic report nothing while the snapshot looks fine. The registry is
  therefore checked against the live host whenever it changes, and staleness is alerted on rather than
  assumed away.
- One target failing does not abort the others, but the run exits non-zero so the failure is recorded
  rather than masked.
- **The local repository is on the root disk, so it is not offsite.** It survives the loss modes it was
  built for (deletion, bad migration, logical corruption) and explicitly does not survive losing the
  host — which is what the R2 leg is for. **That leg is not running yet:** the R2 bucket exists and is
  empty, and creating the S3 credentials is a dashboard action. Until it runs, the only copy that
  survives losing the node is the **workstation mirror — and as of 2026-09-29 that is no longer a manual
  afterthought**: a systemd user timer pulls it daily, `Persistent=true` catches a run missed while the
  machine was off, and the first unattended run finished in 28 seconds with `restic check` clean over 40
  snapshots (DR-003). It is a copy outside both providers, which is the property the R2 leg was wanted
  for; what R2 would add is not having to trust one laptop.
- `restic`'s version is pinned, because it *writes* the repository format and an unattended upgrade
  changes the on-disk format the snapshots are stored in.
- Losing the restic password loses the repository — the same custody problem as the `age` keys, and the
  reason both live in the password manager as well as on the workstation.
- Restores are documented per dataset rather than per engine, because the drill is what keeps them
  honest.

## Evidence

`ansible/roles/backup/` (scripts, units, defaults), `ansible/files/backup-targets.yaml`,
`docs/backups.md`, `docs/runbooks/restore-*.md`, and `scripts/pull-backups.sh`.
