# Runbook: restore a Postgres database

Applies to the in-cluster Postgres DBs: `vcap-dev`, `vcap-staging`, `meghmitra`, `bitvault`.

**Source of dumps: the automated restic repository** (`/var/backups/restic` on the node, S4).
Class A (`vcap-staging`, `meghmitra`) is dumped every 30 min, class C daily. The S0 bundle is the
independent fallback and gets staler by the day — see [`../disaster-recovery.md`](../disaster-recovery.md)
for which copy survives what.

## Getting a dump out of the repository

```bash
# On the node as root (the repo is root-owned, mode 0700).
set -a; . /etc/vps-backup/env; set +a          # RESTIC_PASSWORD, mode 0600, rendered from SOPS
export RESTIC_REPOSITORY=/var/backups/restic

restic snapshots --tag class-A                  # or class-C
restic restore latest --tag class-A --target /tmp/restore
# Inside the snapshot, dumps live at:
#   /tmp/restore/var/backups/staging/class-A/pg/<namespace>-<workload>.dump
#   …and a matching -globals.sql (roles) beside it
```

From the workstation the password is `sops -d ansible/group_vars/vps/secrets.sops.yaml`
(key `restic_password`); if the node is gone, the repository is gone with it — use the S0 bundle or
the workstation mirror instead.

Each namespace's Postgres exposes `POSTGRES_DB`/`POSTGRES_USER`/`POSTGRES_PASSWORD` as pod env vars
from a Secret, so use them from *inside* the pod and credentials never reach your shell history.

## Variant A: verify a backup without touching production

The monthly drill (`ansible/roles/backup/templates/vps-restore-test.sh.j2`) does exactly this and is
the executable reference: restore the snapshot → stand up throwaway pods in a `restore-test`
namespace → `pg_restore --list` → import into a scratch database → **compare table lists and row
counts against the live database** → delete the namespace. Measured on 2026-09-28: both class-A
databases imported and matched exactly (1 385 and 48 672 rows), in under five minutes.

Doing it by hand:

```bash
NS=restore-test
kubectl create namespace "$NS"

# Use the SOURCE app's image, not a generic postgres tag: meghmitra needs PostGIS, and a plain
# postgres image loses the extension-owned tables (geometry_columns, spatial_ref_sys) silently —
# the dump "restores" and is quietly incomplete.
SRC_IMAGE=$(kubectl -n meghmitra get pod -l app.kubernetes.io/name=postgres \
  -o jsonpath='{.items[0].spec.containers[0].image}')

# An explicit manifest, NOT `kubectl run … -- sleep infinity`: that overrides the entrypoint, so
# Postgres never starts and every later step fails for a confusing reason.
kubectl apply -n "$NS" -f - <<EOF
apiVersion: v1
kind: Pod
metadata: {name: pg-scratch}
spec:
  restartPolicy: Never
  containers:
    - name: postgres
      image: $SRC_IMAGE
      env:
        - {name: POSTGRES_PASSWORD, value: scratch}
        - {name: POSTGRES_USER, value: drill}
        - {name: POSTGRES_DB, value: drill}
      resources:
        requests: {memory: 256Mi}
        limits: {memory: 1Gi}
EOF

# Wait for the FINAL server, over TCP. `pg_isready` on the unix socket also succeeds against the
# entrypoint's temporary init-time server, which then shuts down mid-restore.
until kubectl -n "$NS" exec pg-scratch -- pg_isready -h 127.0.0.1 -U drill >/dev/null 2>&1; do sleep 3; done

kubectl cp /tmp/restore/.../pg/<ns>-<workload>.dump "$NS"/pg-scratch:/tmp/restore.dump
kubectl exec -n "$NS" pg-scratch -- pg_restore --list /tmp/restore.dump | wc -l   # sanity: TOC entries
kubectl exec -n "$NS" pg-scratch -- sh -c \
  'psql -U drill -d postgres -c "create database imp" && \
   pg_restore -U drill -d imp --no-owner --no-privileges /tmp/restore.dump'

# The assertion that matters: table lists and row counts vs the live database.
kubectl exec -n "$NS" pg-scratch -- psql -U drill -d imp -tAc \
  "select count(*) from information_schema.tables where table_schema='public'"

kubectl delete namespace "$NS"
```

## Variant B: restore in place after real data loss

⚠️ This overwrites live data. Take a dump of the *current* (post-incident) state first if it may
still have value, and confirm the target with whoever owns the app.

```bash
NS=vcap-staging                 # e.g.
DEPLOY=vcap-backend-staging-postgres
POD=$(kubectl get pods -n "$NS" -o name | grep "$DEPLOY" | head -1 | cut -d/ -f2)

kubectl cp <dump-file>.dump "$NS"/"$POD":/tmp/restore.dump

kubectl exec -n "$NS" "$POD" -- sh -c '
  set -e
  PGPASSWORD="$POSTGRES_PASSWORD" dropdb -U "$POSTGRES_USER" "$POSTGRES_DB"
  PGPASSWORD="$POSTGRES_PASSWORD" createdb -U "$POSTGRES_USER" -O "$POSTGRES_USER" "$POSTGRES_DB"
  PGPASSWORD="$POSTGRES_PASSWORD" pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" /tmp/restore.dump
  rm -f /tmp/restore.dump
'

kubectl rollout restart deploy -n "$NS"      # pods holding stale connections
```

Validate: expected tables present, app health checks pass, row counts consistent with the dump's
point in time. Roll the `globals.sql` file in separately if roles are missing — it is a plain
`pg_dumpall --globals-only` script, not part of the `.dump`.

## Status

Variant A is **exercised automatically every month** by the drill (which is why the recipe above
records the two traps it taught: the entrypoint's temporary server, and the source image's
extensions). Variant B — the in-place, destructive path — has never been run for real, for the
obvious reason. Treat it as reviewed, not proven.
