# Runbook: restore rankstack's Mongo data

## State as of 2026-09-28 — read this before the rest

- **The replica set is healthy again**: `rs.status()` reports `rs0`, `state: PRIMARY`, one member,
  `ok: 1`. The `InvalidReplicaSetConfig` failure the architecture review recorded is fixed (S13).
- **The dump works**: `mongodump --archive --gzip --oplog` runs cleanly every day with the class-C
  set, and lands in restic at
  `/var/backups/staging/class-C/mongo/rankstack-rankstack-mongo.archive.gz`.
- **There is nothing meaningful to restore today**: the `rankstack` database holds **0 documents**
  (5 collections). The 369 MB `docs/storage.md` used to list for it is WiredTiger preallocation. The
  1.4 KB archive is therefore correct, not a symptom — that is what an empty database dumps to.
- **It has never been restore-tested.** Nothing in this procedure has been executed, unlike the class-A
  drill. Treat it as reviewed-but-unproven, and treat the class-C data as disposable (the owner
  accepted that loss explicitly — `docs/storage.md`).

## Getting a dump out of the repository

```bash
ssh vps 'set -a; . /etc/vps-backup/env; set +a; export RESTIC_REPOSITORY=/var/backups/restic
  restic restore latest --tag class-C --target /tmp/restore'
# → /tmp/restore/var/backups/staging/class-C/mongo/rankstack-rankstack-mongo.archive.gz
```

Because the dump is taken with `--oplog`, a restore must replay it:

```bash
POD=$(kubectl -n rankstack get pods -o name | grep mongo | head -1 | cut -d/ -f2)
kubectl cp <archive.gz> rankstack/$POD:/tmp/restore.archive.gz
kubectl exec -n rankstack "$POD" -- mongorestore --archive=/tmp/restore.archive.gz --gzip \
  --oplogReplay --drop
```

Note the S0 bundle holds **no** usable Mongo copy (that dump failed at the time), so restic is the only
source for this dataset.

## Target path (once S13 fixes the replica set)

```bash
NS=rankstack
POD=$(kubectl get pods -n "$NS" -o name | grep rankstack-mongo | head -1 | cut -d/ -f2)

kubectl cp <archive-file>.gz "$NS"/"$POD":/tmp/restore.archive.gz
kubectl exec -n "$NS" "$POD" -- mongorestore --archive=/tmp/restore.archive.gz --gzip --drop
kubectl exec -n "$NS" "$POD" -- rm -f /tmp/restore.archive.gz
```

Validate: `kubectl exec -n rankstack "$POD" -- mongosh --quiet --eval "rs.status().myState"` returns
`1` (PRIMARY); `api-rankstack.upayan.dev` answers without crash-looping.

## Fallback path usable today: data-directory recovery

Only viable if you have a filesystem-level tar of the PVC's data directory (e.g. taken while the
pod was stopped, for consistency) — **not currently true**, since S0 only tarred live directories
for datasets where the DB engine itself handled dump-based backup; rankstack Mongo was not
tarred because it wasn't identified as needing it until the `mongodump` failure surfaced.

If such a tar exists in the future:

```bash
NS=rankstack
kubectl scale deploy/rankstack-mongo -n "$NS" --replicas=0
# untar the archive onto the PV's host path (find it via `kubectl get pv <pv-name> -o yaml`, `.spec.local.path`)
tar -xzf <mongo-data-tar>.tar.gz -C <pv-host-path>
kubectl scale deploy/rankstack-mongo -n "$NS" --replicas=1
```

Then re-run the replica-set init (`rankstack-mongo-rs-init` Job) if the restored data doesn't
already have a consistent `rs0` config.

## When this hasn't been tested

Neither path above has been exercised end-to-end. A live restore test for Mongo specifically
requires S13's replica-set fix to land first (the current member config is broken regardless of
data validity) — until then, treat any Mongo recovery as best-effort, and dump the current state
via `mongoexport`/manual queries where possible before attempting anything destructive.
