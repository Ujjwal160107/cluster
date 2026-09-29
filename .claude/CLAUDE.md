# vps — k8s GitOps repo

This repo is the **single source of truth** for a k3s cluster on Hetzner DE.
All cluster state lives in `k8s/`. Push to `main`; ArgoCD reconciles automatically.
`kubectl` is break-glass only — `selfHeal: true` reverts manual changes within minutes.

## Hard rules

1. **Never `kubectl apply/create/delete/patch/edit` for changes that should live in git.**
   `selfHeal: true` is on every app **but one** — manual kubectl changes revert within minutes. The exception
   is `hetzner-csi`, the only Application with no `automated` policy at all (verified 2026-09-29: 28 of 29 carry
   `prune=true, selfHeal=true`): an edit under `k8s/hetzner-csi/` applies **only** when someone syncs it, so it
   sits `OutOfSync` until then, and `kubectl -n argocd patch app hetzner-csi --type merge -p '{"operation":
   {"sync":{"prune":false}}}'` is the deliberate way to apply one.
   All persistent cluster config changes go through: edit `k8s/` → commit → `git push origin main`.

2. **Permitted break-glass kubectl writes:**
   - `kubectl apply -f k8s/bootstrap/root-app.yaml` (root app bootstrap — one-time per cluster)
   - `kubectl rollout restart deploy/<name> -n <ns>` (force pod restart after a Secret commit)
   - `kubectl delete pod <name> -n <ns>` (kill a stuck pod; ArgoCD recreates from manifest)
   - `kubectl -n argocd annotate app <name> argocd.argoproj.io/refresh=hard --overwrite`

3. **Only branch is `main`.** The `argo` branch was deleted.

4. **Secrets are SOPS-encrypted (`secrets.sops.yaml`) in this private repo.** No plaintext
   `Secret` manifest remains under `k8s/` (all converted 2026-09-28, stage S5): each app directory
   has a `secrets.sops.yaml` whose `stringData` is SOPS/age-encrypted, applied through a `ksops`
   generator. Two things this does NOT mean: the values are still the **original, unrotated**
   credentials, and they are still in git **history** — encryption is not rotation. Rotation order
   and the post-rotation `git filter-repo` rewrite are in `docs/secrets.md`, owner-gated.
   The last plaintext credential home in this repo — the vcap Helm **values** files — **closed
   2026-09-29** (SEC-003): the six vcap Secrets (`backend-env`, `auth-env`, `pull-secret` in `vcap-dev`
   and `vcap-staging`) live in `k8s/apps/vcap/secrets/{dev,staging}/secrets.sops.yaml`, emitted by a
   ksops generator that is a **separate multi-source** of the same Application (a git-sourced Helm
   chart cannot run a ksops generator alongside `kustomize --enable-helm`; multi-source is the way
   around it). `helm-secrets` is still not installed and still not needed. **Consequence to remember:**
   those Deployments checksum the chart's own `secret.yaml`, which now renders nothing, so editing a
   value in `secrets.sops.yaml` **no longer rolls the pods** — follow a credential change with
   `kubectl rollout restart deploy/<name> -n vcap-{dev,staging}` (rule 2 permits exactly that).
   Never print a secret value in shared output; edit one with
   `sops k8s/apps/<app>/secrets.sops.yaml`, and render locally with
   the offline age key, which sops finds in its default location.

5. **Every cluster-affecting action gets a changelog entry.** This includes git-tracked changes
   under `k8s/` *and* every break-glass `kubectl` write from rule 2. Log it in
   `changelog/YYYY-MM.md` in the same commit (git changes) or immediately after (break-glass ops,
   since kubectl bypasses git). Format and rules: `changelog/README.md` /
   `.claude/skills/changelog/SKILL.md`. Break-glass entries are the only audit trail those actions
   ever get — do not skip them.

## Workflow

```
edit k8s/ → git commit → git push origin main → ArgoCD reconciles (~3 min, or hard-refresh)
```

**`git pull` before you push.** `argocd-image-updater` now writes digest pins back to `main` as
commits authored by `argocd-image-updater <image-updater@upayan.dev>` (`build: automatic update of
<app>`, adding `.argocd-source-<app>.yaml`). Expect them, and do not "fix" or revert them — they are
the intended `git` write-back, and a stale local `main` will simply be rejected on push.

## Cluster facts

- Node: `vps` · k3s · Hetzner DE · `138.201.157.147`
- ArgoCD app-of-apps: root app watches `k8s/argocd/` recursively from `main`
- Projects: `platform` · `apps` · `vcap`
- TLS: Traefik's default certificate is a Cloudflare Origin CA wildcard (`*.upayan.dev`, expiring
  2027-09-28 — one year, renewed by hand, so it needs an expiry alert),
  set by `TLSStore default` in `kube-system`; its Secret is SOPS-encrypted in `k8s/platform/traefik/`.
  No per-app TLS Secrets, no ACME, cert-manager removed — Ingresses declare no `tls:` (see `docs/certificates.md`)
- Secrets: SOPS+age **is live** — every `Secret` manifest under `k8s/` is `secrets.sops.yaml`,
  decrypted by a `ksops` generator (see rule 4). Unrotated: the values are the originals and are
  still in git history. Rotation + history rewrite: `docs/runbooks/rotate-secrets.md`, owner-gated

## Directory map

```
k8s/
  bootstrap/root-app.yaml       ← applied once via kubectl; starts ArgoCD self-management
  argocd/
    projects/                   ← apps.yaml  platform.yaml  vcap.yaml
    applications/               ← explicit apps: platform/  apps/ (multi-image/Helm workloads)  vcap/
    applicationsets/            ← apps.yaml (list generator; one element per single-image app — NOT auto-discovered)
  apps/
    <app>/                      ← flat; ArgoCD app name = namespace = folder (add a list element + project namespace)
  platform/                     ← argocd  argocd-image-updater  keda  traefik  (no velero/ — see note below)
  monitoring/                   ← Prometheus  Grafana  Loki  Promtail
```

## Public-repo tooling (added 2026-09-29)

- **`scripts/private/` is excluded from the public tree *by rule*.** Anything that must not be published
  lives there — today `export-public.sh` (builds the public tree), `redact-public-tree.py` (the changelog
  redaction mapping) and `check-public-redaction.sh` (the gate). Do not add a private script elsewhere and
  do not start excluding them one by one: a list of names is exactly what let four personal addresses sit
  in `changelog/2026-09.md` unnoticed.
- **PUB-002 is a command, not a careful pass.** `scripts/private/export-public.sh --out DIR` copies the
  allowlisted tracked files, redacts the changelog, and **exits 1 without handing anything over** unless
  `check-public-redaction.sh` is clean. It currently names two source files that must be fixed *at
  source* by their owning tasks — both VCAP-owned values files (VCAP-004/005). It named five on 2026-09-29;
  the other three (the inventory contacts, the Grafana contact points, the inventory's key-name comments) were
  cleared that night. The policy it enforces is the redaction checklist, held with the private
  archive and not published (it names the terms).
- **Two decisions widened the published surface:** the changelog ships **redacted** rather than excluded
  (D-5), and `.claude/` ships too (D-8). Both are the owner's calls. Their consequence is recorded as an
  open question in that checklist: publishing this directory also publishes a description of what is
  currently broken.

## Known broken or fragile items (checked 2026-09-28; extended 2026-09-29)

| Item | Symptom | Cause / status |
|---|---|---|
| ~~Registry credentials are all dead~~ | **resolved 2026-09-28** | The owner refreshed the `gh` token with `write:packages`; it now backs the pull-secrets and `argocd/ghcr-creds`. image-updater is at `errors=0`, the vcap worker image is cached, bitvaultd was re-pulled, and MinIO runs from our own mirror. Rotating this token again: update the CLI's token, then re-apply the four Secrets and delete `argocd-image-updater`'s pod |
| ~~`vcap-staging-backend/worker` image absent~~ | **resolved 2026-09-28** | Pulled onto the node once the credential worked. `pod-image-pull-failing` (warning, 10m) now alerts on that whole class |
| ~~`bitvaultd` blobs pruned~~ | **resolved 2026-09-28** | The working token makes it pullable again (verified). Still not *exportable* to a tarball — a layer blob its pull never needed is absent from the content store — which does not affect pulling, running or a rebuild |
| `hetzner-csi` | — | **Resolved 2026-09-28**: the Application was synced for the first time when `hcloud-volumes` stopped being a cluster default; it is now `Synced`/`Healthy` and no longer reports OutOfSync. **Not load-bearing:** `hcloud-volumes` has 0 PVs — the `smart-home-system-api` PVC binds `local-path`, and `vps-data` is an Ansible-mounted volume, not a CSI claim — so neither the StorageClass nor the Hetzner API token backs anything today |
| `smart-home-system-api` | pods stick in `ContainerCreating` on `FailedAttachVolume` when KEDA scales it from zero | Its PV points at a Hetzner volume **deleted during S8**, so it can never attach. Class C, criticality "none" (owner-classified) — data is disposable. Two options: repoint its PVC at `local-path` (a small manifest change, gives it empty storage), or retire the app. Undecided, hence this row |
| `meghmitra` (the app, not the hostname) | being replaced | The application deployed there — Node web + API over **PostGIS**, images `ghcr.io/xarhaanshx/meghmitra/*` — is being handed over to a different repository, `Ujjwal160107/adhigrahan-radar`, which hosts **a different application** (Adhigrahan Radar: FastAPI + a Vite SPA over **SQLite**). PR #3 adds its containerisation and `deploy/`; the running deployment is untouched until the replacement is validated (MEGH-002), and the old PostGIS data has **no migration path** into the new store — that disposition is MEGH-003 and the owner's call. Hostname and namespace stay `meghmitra` |
| ArgoCD reports `Synced` at an older revision | a merged manifest change applies nowhere | `status.reconciledAt` is **not** "compared against current `HEAD`": an app can reconcile every few minutes while its resolved revision is twenty minutes stale, so `Synced` means "no diff against *that* revision". A change that does not appear is a **refresh** problem first and a rendering problem second — compare `status.sync.revision` with `origin/main`, then `kubectl -n argocd annotate app <name> argoproj.argoproj.io/refresh=hard --overwrite` (permitted break-glass; log it). Hit 2026-09-29 on `monitoring` after an alert rule merged |
| `api-bandit.upayan.dev` | `502` | bandit's own PM2 backend never binds `:5000`: MongoDB Atlas rejects the connection (allowlist). Atlas is out of scope in `docs/storage.md`; the frontend host is healthy |
| `qwik.dj.upayan.dev`, `react.dj.upayan.dev`, `api.ks.upayan.dev` | TLS handshake failure at the **Cloudflare edge** | Cloudflare Universal SSL covers `upayan.dev` + one wildcard level, so two-level names have no certificate. Not fixable from the origin — use single-level hyphenated API hostnames (the convention everywhere else) or add an edge certificate |

**Tokens on the workstation.** A Cloudflare API token (*SSL and Certificates: Edit*, expires
2027-01-03) is stored outside both repositories — as is every other credential — and is used for
origin-certificate issuance and revocation; it deliberately has no R2 scope. Read it into an
environment variable at point of use — never print it, and never write its location into a file that
this repository publishes.

**Backups live on the node, but the offsite leg is current.** The restic repository is on the root
disk — so losing the node takes it — but the Cloudflare R2 offsite copy is **live and succeeding**
(hourly, and class A every 30 min; 47 snapshots as of 2026-09-29). `/var/backups/images` holds the
unrepullable image tarballs and is node-local. Details: `docs/disaster-recovery.md`.

**Namespace deletion gotcha (learned 2026-09-28).** A namespace can wedge in `Terminating`
reporting `NamespaceDeletionDiscoveryFailure: … external.metrics.k8s.io/v1beta1: stale
GroupVersion discovery`. That is **not** an unreleased finalizer — it means the namespace controller
could not enumerate API groups because an aggregated APIService (KEDA's external metrics server) was
briefly unreachable, and it then never retried successfully. Four namespaces were stuck this way
(`velero`, `hello-kitty`, `ns-68f3b786…-nginx`, and `cert-manager` after its removal); all four were
provably empty and were cleared by emptying `.spec.finalizers` through the `/finalize` subresource.
If it recurs: confirm the namespace is empty first, then
`kubectl get ns X -o json | jq '.spec.finalizers=[]' | kubectl replace --raw /api/v1/namespaces/X/finalize -f -`.

**Velero does not exist anywhere in `k8s/`** — it was never committed despite once being listed in
this table and in the directory map above; treat any mention of it elsewhere as stale.

## Sub-agents available

- `.claude/agents/cluster-ops` — inspect live cluster, pod logs, trigger syncs
- `.claude/agents/app-add` — scaffold a new app folder, commit, and push
- `.claude/agents/app-debug` — diagnose OutOfSync / Degraded / Missing apps

## Reference docs

- `.claude/skills/cluster-state/SKILL.md` — full app inventory + ArgoCD project map
- `.claude/skills/app-onboarding/SKILL.md` — add-app guide with file templates
- `.claude/skills/argocd-ops/SKILL.md` — sync/refresh/rollback/diff command reference
- `.claude/skills/secrets-tls/SKILL.md` — secrets policy + TLS/Origin-CA patterns
- `.claude/skills/changelog/SKILL.md` — forensic changelog format, when an entry is required
- `changelog/` — forensic timeline of every cluster change (git + break-glass), split by month
- `docs/README.md` — the S1 architecture-programme documentation set (architecture, inventory,
  storage, backups, disaster recovery, ports, networking, secrets, certificates, monitoring,
  maintenance, upgrade policy, runbooks) — start here for anything beyond day-to-day `k8s/` edits
- The architecture review (S0–S13) — the staged implementation plan this repo executed; kept in
  the private archive and not part of the published tree (S0 onward landed, see `changelog/2026-09.md`)
