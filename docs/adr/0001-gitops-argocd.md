# 0001. GitOps with ArgoCD (app-of-apps)

- **Status:** Accepted
- **Date:** 2026-09-28

## Context

One fixed single-node k3s cluster, maintained by one person, serving a mix of personal apps and a
third-party tenant. Deployments must be reproducible from git after a node loss, reviewable as diffs,
and impossible to drift silently. Two things make this harder than a demo: the cluster is on a public
internet address, and some workloads hold student data, so "who can make the cluster do something" is
a security question, not a convenience question.

## Decision

`git` is the only source of truth, and ArgoCD is the only deployment mechanism.

- **App-of-apps.** `k8s/bootstrap/root-app.yaml` is the single Application ever applied by hand. It
  points at `k8s/argocd/` with `directory.recurse: true`, so adding a file there creates an AppProject
  or Application within seconds. (Planned move: `bootstrap/root-app.yaml` and `clusters/vps/` — see the
  migration plan's `CLUSTER-002`; the layout below is written for that target, and every path listed
  under *Evidence* is the one that exists today.)
- **Three AppProjects, not one.** `platform` (cluster infrastructure), `apps` (the owner's workloads),
  `vcap` (the tenant). Each enumerates its destination namespaces and its cluster-scoped kinds
  explicitly — a mismatch fails loudly (`namespace X is not permitted in project Y`) instead of
  deploying somewhere unexpected.
- **ApplicationSet for the long tail, explicit Applications for the exceptions.** A list generator
  produces one Application per single-image app; anything with two images or a multi-source Helm chart
  gets its own file.
- **`automated: prune + selfHeal` on every child app**, with `ServerSideApply=true` so a merge never
  strips a field another controller owns.
- **Break-glass is enumerated, not implied.** Exactly four `kubectl` writes are permitted without a
  commit: applying the root app, a `rollout restart`, deleting a stuck pod, and a hard refresh. Anything
  else that changes state has to go through git.

## Alternatives rejected

- **Flux.** Equivalent capability; the cluster already ran ArgoCD, and its AppProject model is the
  mechanism that expresses the tenant trust boundary here.
- **CI pushes (`kubectl apply` in a pipeline).** No reconciliation: drift is invisible, and the cluster
  state diverges from git the first time someone touches it by hand. Also puts a cluster-admin
  credential in CI.
- **ArgoCD "application in every app repo".** Rejected as the default because an Application is a
  cluster-security object (it names the AppProject, the namespace and the cluster). See ADR 0003.

## Consequences

- Every persistent change is a commit with a reviewable diff, and a rollback is `git revert`.
- `selfHeal` means a manual `kubectl edit` is reverted within minutes, which is a feature and a trap —
  the permitted break-glass list exists so the trap is documented.
- Application **names are API**: `.argocd-source-<name>.yaml` filenames in tenant repos and ArgoCD's
  resource finalizers both depend on them, so names are never changed during a migration.
- The root Application is deliberately outside its own management (bootstrap-only), so changing *its*
  project or path needs the one permitted break-glass apply.
- **Known gap, recorded rather than hidden:** every live generated Application carries
  `resources-finalizer.argocd.argoproj.io`, but the ApplicationSet **template** does not declare it —
  it was added out-of-band. So removing an ApplicationSet element cascade-deletes workloads even though
  git does not say so. Closing that is tracked work (`ARGO-001`/`CLUSTER-003`).

## Evidence

`k8s/bootstrap/root-app.yaml`, `k8s/argocd/projects/{platform,apps,vcap}.yaml`,
`k8s/argocd/applicationsets/apps.yaml`, `k8s/argocd/applications/{platform,apps,vcap}/`, the ArgoCD
sections of `docs/architecture.md`, and the AppProject-scoping notes in
`.claude/skills/cluster-state/SKILL.md`.
