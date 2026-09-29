# backup role

Deploys `vps-backup.sh` (per-class dump + restic), `vps-etcd-snapshot.sh`, `vps-backup-prune.sh`
(weekly retention), `vps-backup-offsite.sh` (DR-001 — hourly `restic copy` of every tag to Cloudflare
R2; a no-op until a destination is configured, see below), the targets registry, and their systemd
service/timer units (`vps-backup-classA` 30-min, `vps-backup-classC` daily, `vps-etcd-snapshot` 12h,
`vps-backup-prune` weekly, `vps-backup-offsite` hourly). Installs `restic`, `jq`, `yq`. Renders
`/etc/vps-backup/env` (mode 0600, `no_log`) from SOPS-encrypted group vars — and nothing else: the R2
credentials are host-local (`/etc/vps-backup/r2.env`) and deliberately never pass through Ansible,
SOPS or git.

**The role deliberately does not `restic init` and does not enable or start any timer** — both are
separate, explicitly confirmed steps.

## State on the host (2026-09-28)

Applied and running: the timers are enabled on the node and backing up into
`/var/backups/restic` (an **interim local repository**, see below). First verified runs exited 0 and
the snapshots were restore-tested — see `docs/backups.md` and the changelog.

## Gated step: `restic init`

⚠️ Confirm the repository path is genuinely empty before running this. It was run on 2026-09-28 only
after checking `/var/backups/restic` did not exist.

⚠️ **Run the playbook from the `ansible/` directory.** `ansible/ansible.cfg` is what enables
`community.sops`' vars plugin, and Ansible only reads a cwd `ansible.cfg`. From the repo root the
SOPS vars stay encrypted and the role writes `ENC[AES256_GCM,…]` in as the restic password — which
happened on 2026-09-28 and broke the class-A backups until it was traced. The role now asserts
against it, but the invocation is the real fix:

```bash
cd ansible && ansible-playbook site.yml --limit vps
```

```bash
# Interim local repository (current state) — root filesystem, deliberately not /srv/data:
ssh vps "install -d -m 700 /var/backups/restic"
ssh vps 'set -a; . /etc/vps-backup/env; set +a; \
  RESTIC_REPOSITORY=/var/backups/restic restic init'

# Target: R2. Requires the R2 S3 credentials, then set backup_restic_repository to
# s3:https://<account-id>.r2.cloudflarestorage.com/vps-backups, add r2_access_key_id /
# r2_secret_access_key to group_vars/vps/secrets.sops.yaml (and to the env-file task), re-run this
# role, init the new repo, then re-point the timers.
```

Enabling the timers (done on the host 2026-09-28; the prune timer is **not optional** — without it
the repository only grows):

```bash
systemctl enable --now vps-backup-classA.timer vps-backup-classC.timer \
  vps-etcd-snapshot.timer vps-backup-prune.timer
```

`vps-backup-offsite.timer` is deployed but deliberately **not** in that list: it stays disabled until
the R2 credentials exist and the destination has been initialised — the section on the offsite leg
below has the sequence.

## What's deployed vs. what's still missing

Deployed: dump scripts, targets registry, restic env file, all four service/timer units, and
`vps-backup-prune` retention (class A `--keep-within 48h --keep-daily 30 --keep-weekly 12
--keep-monthly 12`; class C `--keep-daily 7`).

Deployed 2026-09-28 (later): `vps-restic-check.{sh,service,timer}` (weekly integrity + 10% data
read), `vps-restore-test.{sh,service,timer}` (monthly end-to-end drill), and the etcd script now
pushes snapshots plus the k3s server token/TLS to restic under `--tag etcd`.

Deployed 2026-09-29 (DR-001, offsite): `vps-backup-offsite.{sh,service,timer}` — the hourly
`restic copy` of every tag to a second, independent repository in Cloudflare R2. Deployed but **not
enabled**: the R2 S3 credentials do not exist yet, so it no-ops (see the offsite section below).

**Still missing** (tracked, not silently skipped):

- R2 bucket-lock tolerance validation (review §12.7). Two distinct questions now that R2 holds a
  *copy*: the offsite repository is never pruned (nothing deletes from it, by design), so it only ever
  grows; and whether a future `restic forget --prune` could ever run against locked objects is
  unvalidated.
- ~~healthchecks.io dead-man URLs~~ — **declined by the owner 2026-09-28**; staleness alerting runs
  through Grafana against `vps_backup_last_success_timestamp` instead.
- (Grafana's sqlite pre-copy was implemented 2026-09-28 — the registry declares `sqlite: grafana.db`
  and the script takes a consistent copy with SQLite's `.backup` before restic reads anything.)

## Restore drill: classes and coverage

`vps-restore-test.sh [A|C]` — the class defaults to `A`, so the historical unit
(`vps-restore-test.timer`, 1st of the month at 05:00 UTC) behaves exactly as before. Class C runs from
`vps-restore-test-c.timer` on the 15th at 06:00 UTC (DR-004, 2026-09-28). The two are a fortnight
apart and must not overlap: each run creates scratch pods, and this node is memory-tight.

Per class the drill: restores the newest `class-<X>` snapshot; checks the pg_dump custom-format magic
on every Postgres dump; imports each dump into a scratch database beside its live counterpart and
requires the table list to match, with no table empty that has rows live; restores each `mongodump`
archive into a scratch `mongo` instance and compares collections and document counts the same way;
diffs each restored MinIO directory against the live one; deletes its scratch namespace; and writes a
**per-class** metric — `vps_restore_test_last_success_timestamp{class="A"}`.

The Mongo restore deliberately does **not** replay the archive's oplog (`--oplog`, which the rankstack
target asks for). The question the drill answers is whether the dumped *data* comes back intact, and
replaying oplog entries against a standalone scratch instance would exercise a path production never
takes — the live instance is a replica-set member. mongorestore's output is parsed for its failure
*counts* rather than grepped for the words "error"/"failed", because its own summary line contains
"0 document(s) failed to restore" and a check that reports failure on a clean restore is one that gets
ignored.

Why the label is load-bearing: without it a class-C run would satisfy the class-A staleness alert
(`vps-restore-test-stale`, 40 days, `noDataState: Alerting`). The pre-DR-004 *unlabelled* metric file
is removed on a class-A run only — on success the labelled series replaces it, and on failure the
alert's `noDataState: Alerting` says exactly the right thing ("no successful class-A drill recorded").
A class-C run leaves it alone, because class C cannot supply the class-A series.

**Coverage, stated rather than assumed.** The drill restores `postgres` dumps, `mongo` archives and
`file` trees. Any target of the requested class with an engine it cannot import is printed as `NOT
COVERED` and counted into `vps_restore_test_uncovered_targets{class=…}`; it is not silently counted as
verified. **As of 2026-09-28 nothing in either class is uncovered** — `mongo` was the gap (rankstack),
and it was reported as uncovered by design until the path above existed. That is what the report is
for: the earlier version said so rather than letting the absence read as coverage.

One honest note about what the Mongo check proves today: rankstack's database holds **0 documents**, so
the *count* comparison is 0 = 0 where Postgres compares real numbers. What it does prove is that the
archive restores — 5 collections and their indexes come back into a scratch instance — which is the
part that was previously untested. The counts will become meaningful on their own if the app is used.

## Offsite copy to Cloudflare R2 (DR-001) — deployed, not enabled

`vps-backup-offsite.sh` (hourly `vps-backup-offsite.timer`) copies **every** snapshot — class-A,
class-C, `etcd` and the exported image tarballs — from the local repository into a *second,
independent* restic repository in Cloudflare R2 (`vps-backups`), with
`restic copy --from-repo <local repo>`. It is deliberately a copy rather than a second backup run: the
offsite set is then exactly the set the restore drill has already verified, and `restic copy` is
incremental for free — it lists what the destination holds, skips snapshots it already has, and
uploads only the packs the destination lacks (the equivalent workstation mirror measured 21m44s for
the first copy of the 383 MB repository and 25s for the next, DR-003). `--from-repo`,
`RESTIC_FROM_REPOSITORY` and `RESTIC_FROM_PASSWORD` were verified present in the node's pinned
restic 0.16.4 on 2026-09-29. There is no offsite `forget --prune`: retention is enforced on the local
repository by `vps-backup-prune`, R2 bucket-lock rules exist to make deletion impossible, and the
consequence (the offsite repository only ever grows) is tracked in **Still missing** above.

**On a host with no destination configured the script is a no-op**: it logs and exits 0 without
invoking restic, and writes no metric. That is what keeps this deployment from changing the behaviour
of the host today — the R2 credentials do not exist yet, and the four existing timers and their alerts
are unaffected. Verified by rendering every pre-existing template with the offsite configuration
absent and diffing against `HEAD`: no diff.

### Credentials: `/etc/vps-backup/r2.env` (host-local, never in git or SOPS)

The R2 endpoint (which carries the account id), the S3 key pair, the region and an optional
destination password live in one host-local file. They are **not** rendered by this role, not
SOPS-encrypted and never committed: this repo is moving public, and the account id is not something to
publish. The `vps-backup-offsite` unit loads the file with `EnvironmentFile=` — the same pattern the
other units use for `/etc/vps-backup/env`.

The key pair is the one **scoped to the `vps-backups` bucket** (Object Read & Write). Terraform's
`vps-tfstate` credential is a different, bucket-scoped token and must not be used here: the host is
only ever given the backup one.

### Enabling it (once the R2 S3 keys exist)

1. Mint the keys in the dashboard: **R2 → Manage R2 API Tokens → Create API Token**, scoped to
   `vps-backups` with Object Read & Write. The API cannot mint long-lived keys (it returns
   `10015 No route matches this url`), which is why this step is manual.
2. Create the file on the host, root:root, mode 0600 — replace the placeholders, never commit it:

   ```bash
   ssh vps 'install -m 600 -o root -g root /dev/null /etc/vps-backup/r2.env'
   ssh vps 'umask 077; cat > /etc/vps-backup/r2.env' <<'EOF'
   RESTIC_REPOSITORY=s3:https://<account-id>.r2.cloudflarestorage.com/vps-backups
   AWS_ACCESS_KEY_ID=<r2-access-key-id>
   AWS_SECRET_ACCESS_KEY=<r2-secret-access-key>
   AWS_DEFAULT_REGION=auto
   EOF
   ```

   `AWS_DEFAULT_REGION=auto` is required, not decorative: restic signs with `us-east-1` by default and
   R2 refuses that signature. `RESTIC_OFFSITE_PASSWORD` is optional (see the password note below).
   Do **not** put `RESTIC_PASSWORD`, `RESTIC_FROM_REPOSITORY` or `RESTIC_FROM_PASSWORD` in this file —
   the unit and the script set those, and overriding them breaks the source half of the copy.
3. Initialise the destination **once**. It is a new, empty restic repository; `init` refuses to run
   over a non-empty one, which is the cheap check that the URL really points at the empty
   `vps-backups` bucket:

   ```bash
   ssh vps 'set -a; . /etc/vps-backup/env; . /etc/vps-backup/r2.env; set +a; restic init'
   ```
4. Re-run the role from `ansible/` (`ansible-playbook site.yml --limit vps`). It deploys the script
   and units and still enables nothing. `backup_offsite_repository` can stay empty: the destination
   comes from `r2.env`, which is where the account id belongs.
5. Prove one run by hand, then enable the timer:

   ```bash
   ssh vps 'systemctl start vps-backup-offsite.service; journalctl -u vps-backup-offsite -n 50'
   ssh vps 'cat /var/lib/node_exporter/textfile_collector/vps_backup_offsite.prom'
   ssh vps 'systemctl enable --now vps-backup-offsite.timer'
   ```

The first run copies the whole repository (seconds at the node's measured 101 MB/s to Cloudflare);
later runs move only new packs. The metric `vps_backup_offsite_last_success_timestamp` appears with
the first success, and the Grafana rule `vps-backup-offsite-stale` watches it (>4h,
`noDataState: Alerting`, severity warning). **Before the leg is enabled that rule fires**, because the
script writes no series and the rule treats missing data as failure exactly like the other backup
staleness rules — that is intended: "there is no offsite copy" is true, and it is the gap CLAUDE.md
and `docs/disaster-recovery.md` already record. Enabling the leg is what makes it go quiet.

### The repository password, and how the two repositories authenticate

`restic copy` authenticates against both repositories through separate variables — `RESTIC_PASSWORD`
for the destination, `RESTIC_FROM_PASSWORD` for the source — and omitting the source half fails only
`copy`, with "an empty password is not allowed" (how DR-003 hit it on the mirror). `/etc/vps-backup/env`
supplies the local repository's password as `RESTIC_PASSWORD`; the script reuses that value as the
source password. For the destination:

- **Default (nothing to configure):** initialise the R2 repository with the *same* password as the
  local one, which is what `restic init` in step 3 above does — same choice as the DR-003 mirror.
- **A distinct password,** if the two repositories should not share one: set
  `RESTIC_OFFSITE_PASSWORD` in `r2.env` *and* initialise/add that key on the destination
  (`restic -r "$RESTIC_REPOSITORY" key add`, or `restic init` with it as `RESTIC_PASSWORD`). A
  password later rotated on the local repository must be added to the offsite one too, or the copy
  stops — the same trap DR-003 records for the mirror.

## Known dependency gaps

- **Offsite**: `backup_restic_repository` is `/var/backups/restic` — a *different device* from
  `/srv/data`, so it covers accidental deletion, bad migrations and corruption, but not host loss. The
  DR-001 copy leg into R2 is deployed as of 2026-09-29 but **not enabled** — it needs owner-supplied
  S3 credentials. Until then it is a no-op, and `vps-backup-offsite-stale` fires by design because
  there is no offsite copy (see the offsite section above).
- ~~`healthchecks_backup_url` / `healthchecks_etcd_url`~~ — declined by the owner 2026-09-28.
  Staleness alerting runs through Grafana against `vps_backup_last_success_timestamp` (node-exporter
  textfile collector, wired 2026-09-28).

## Validated

- **2026-09-28, check then apply:** `ok=21 changed=12 failed=0`. Found and fixed beforehand: two
  vcap `path:` entries that pointed at a directory that does not exist (a quiet failure — restic
  reports the missing path and the rest of the snapshot still looks fine), a false claim about a
  Grafana sqlite pre-copy, and a `RESTIC_REPOSITORY` that was assigned but never exported.
- **2026-09-28, restore test:** `restic restore latest` → 187 files / 20.4 MiB; the meghmitra dump
  validated with `pg_restore --list` inside the live postgres pod → 100 TOC entries with the real
  schema.
- **2026-09-28, drill upgraded to import:** `vps-restore-test.sh` now imports each class-A dump into
  a scratch database and requires the table count to match the live database (vcap-staging 57,
  meghmitra 17, both matching; scratch DBs dropped). Listing a dump proves it is well-formed;
  importing it proves the data is restorable.
- **2026-09-28, applied and run:** check / drill / etcd-push all exit 0. `restic check` verified 5
  snapshots and read 10% of pack data; the drill restored 139 files/dirs and validated both dumps
  (100 and 409 TOC entries); the etcd push stored 45.4 MiB (6.2 MiB on disk) tagged `etcd`.
  **Note the drill's first version failed on itself** — it called `kubectl exec "$ns/$name"` without
  `-n`, so every exec errored (stderr suppressed) and the check reported "0 TOC entries". It failed
  loudly, which is the design working, but the fix is `kubectl exec -n "$ns" "$name"`. Do not
  reintroduce the silent-stderr pattern in this script.
