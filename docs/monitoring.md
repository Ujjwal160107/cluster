# Monitoring

Supersedes `../k8s/docs/10-monitoring.md`, which was **removed on 2026-09-29** (CLEAN-001) along with the
rest of `k8s/docs/`; git history holds it. Full detail: the architecture review (private, not published) §13.

## Current state

Stack: Prometheus, Grafana, Loki, Promtail, kube-state-metrics, node-exporter (~600 MiB total,
already live in `k8s/monitoring/`).

### The Grafana admin-password overwrite loop (root cause)

1. `grafana-admin-credentials` in git is the SOPS-held admin credential (`k8s/monitoring/secrets.sops.yaml`). Grafana only reads
   `GF_SECURITY_ADMIN_PASSWORD` **the first time** its sqlite DB is created — after that the
   password lives in `/var/lib/k8s-monitoring/grafana/grafana.db`.
2. A human changes the password in the Grafana UI (it forces this away from the SOPS-held admin credential (`k8s/monitoring/secrets.sops.yaml`)) → sqlite
   and git diverge. Live today: the git credential gets HTTP 401.
3. `grafana-create-dev-user` is an ArgoCD **PostSync hook** that runs on every sync of the
   `monitoring` app, authenticating with the git password → 401 → retries (`backoffLimit: 10`) →
   the sync operation hangs.
4. Twice (2026-08-20, 2026-08-29) the fix applied was `grafana-cli admin reset-admin-password`
   back to the git value — which overwrote the human-set password again. The loop repeats on the
   next `monitoring` commit.

Ruled out as causes: ArgoCD reverting the Secret (`managedFields` show only the
`argocd-controller` for that object), credential regeneration, and the Loki ConfigMap (it *is*
git-tracked despite being listed in `.gitignore` — a separate, harmless doc/reality mismatch).

Public dashboards today: `vcap-dev-logs` and `vcap-staging-logs` (owner keeps these — anonymous
public dashboards streaming pod logs is an accepted risk, apps must not log secrets) plus a
hello-kitty dashboard slated for removal (S10, hello-kitty is archived).

## Target fixes (S9, not yet implemented)

- **Fix**: git (via SOPS once S5 lands) becomes the single source of truth for the admin password.
  A Grafana initContainer runs `grafana cli admin reset-admin-password --password-from-stdin` from
  the Secret **on every start** (idempotent) — docs will say "change it in git, never in the UI."
  The user-provisioning Job becomes a plain idempotent Job (not a PostSync hook), `restartPolicy:
  Never`, `backoffLimit: 2`, pinned image, no secrets echoed. Grafana Deployment gets `strategy:
  Recreate` (sqlite is RWO, can't do rolling updates safely).
- Loki: enable compactor retention (7 days — currently unenforced, 5.2 GB and growing).
- Prometheus: pin the image, add `--storage.tsdb.retention.size=4GB`.
- node-exporter: bind `127.0.0.1` or drop `hostNetwork` (also closes the public-exposure gap, see
  [`networking.md`](networking.md)); mount the textfile collector for backup-status metrics.
- New scrape targets: Traefik.
- Alert rules (all critical ones `noDataState: Alerting`): disk > 80%, inodes > 80%, memory > 90%
  for 15m, node NotReady, pod CrashLoop/OOM, PVC/volume > 85% on `/srv/data`, ArgoCD app
  Degraded/OutOfSync > 30m, backup age too old, `restic check` failed, cert < 14 days, Prometheus
  target down, Loki ingestion stopped, and a Watchdog heartbeat routed to healthchecks.io (catches
  "whole VM down," which in-VM alerting structurally cannot).
- No dedicated Postgres/Redis/MinIO exporters planned — the DBs are tiny; pod readiness + backup
  success + volume usage cover the actionable failure modes. Revisit only if a DB becomes
  business-critical enough to need query-level visibility.
- Promtail is end-of-life upstream; migrating to Grafana Alloy is a later, separate change — not
  part of this programme.

## Related

- [`backups.md`](backups.md) — backup-failure alerting is part of the S9 alert set
- [`certificates.md`](certificates.md) — cert-expiry alerting
- `k8s/docs/10-monitoring.md` — the doc this page supersedes; **deleted 2026-09-29** (CLEAN-001), so it is
git history now, not a link (it included the old credentials table, since removed then)
