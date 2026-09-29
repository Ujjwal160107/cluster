# 0003. Tenant model: the cluster repo registers tenants, tenant repos own their deployment config

- **Status:** Accepted (the tenant side is contingent on the tenant team's agreement — see below)
- **Date:** 2026-09-28

## Context

One workload on this cluster is not the owner's: a third-party team's application, which ships its own
Helm chart in its own repositories and whose images are built by its own CI. There is also real student
data in one of its databases.

How the deployment config is split decides three things: who can change what the tenant runs, who the
public cluster repository is allowed to describe, and who can rotate the tenant's credentials without
asking the owner.

The state this replaces was inconsistent rather than chosen: the tenant's chart lived in the tenant's
repo, its images were pinned by a bot writing `.argocd-source-*.yaml` into that repo, but its
environment values **and plaintext secrets** lived in the cluster owner's repo, and one of its
NetworkPolicies lived in a third place (`frontend-manifests`). One deploy state, three repositories,
and the tenant could not rotate its own credentials.

## Decision

**The cluster repository owns the platform and a thin, cluster-specific registration per tenant. The
tenant's repository owns the deployable artifact and the tenant's environment configuration.**

Cluster repo owns:

- the `vcap` AppProject, with **no cluster-scoped kinds** it cannot justify;
- the tenant's Namespaces (with Pod Security Admission labels) and static PersistentVolumes — a
  namespace and a volume are cluster objects;
- the tenant's `Application` objects (~40 lines each, changed rarely), because an Application decides
  the AppProject, the namespace and the cluster, which is a trust-boundary decision;
- shared infrastructure the tenant depends on: ingress controller and TLS store, KEDA, monitoring,
  ArgoCD and image-updater, host-level backups.

Tenant repo owns:

- the Helm chart (already there);
- `deploy/<cluster>-<env>/values.yaml` — environment values next to the chart they configure;
- `deploy/<cluster>-<env>/secrets/secrets.sops.yaml` — SOPS-encrypted, so the tenant holds and can
  rotate its own credentials;
- its own NetworkPolicies (rendered by the chart), and the image-updater write-back files it already
  receives.

**Rule of thumb for future apps:** if another party owns the application repo and it ships its own chart
or its own secrets, it is a **tenant** — app repo owns chart + values + SOPS secrets, cluster repo owns
only the registration. Otherwise it is a **cluster-owned app** under `apps/`.

## Alternatives rejected

- **The cluster repo owns everything about the tenant, including values and secrets** (the status quo).
  It publishes a third party's environment configuration and application-security settings (which email
  domains may sign in, seeding, resource sizing) in the owner's repository, and every tenant config
  change becomes a pull request against the owner's portfolio repo. It also makes the tenant's
  credentials unrotatable by the tenant.
- **The tenant repo also owns its `Application` objects.** An Application names which AppProject, which
  namespace and which cluster a workload may use; letting a repository the owner does not control emit
  those widens the trust boundary for no benefit, and the tenant's repo has no CODEOWNERS or observable
  branch protection to lean on. Chart + values + secrets are the parts that change often; the
  Application is not.

## Consequences

- A tenant deploy state stops being split: the digest pins, the chart and the values are in one place,
  so a chart fix and a values change can land atomically (the earlier static-PV migration needed exactly
  that and had to touch both repositories).
- The public cluster repository never contains tenant values, tenant secrets or tenant
  app-security settings — which also removes the reason to keep the cluster repo private.
- The cluster repo's "definition of done" for the tenant is: chart + values + SOPS secrets exist in the
  tenant repo, only the registration is here, and no tenant values or secrets remain in the cluster
  repo.
- The tenant's `.sops.yaml` needs the cluster's public age recipient (so the cluster can decrypt during
  a sync) plus the owner's — and optionally the tenant maintainer's — so rotation does not require the
  owner.
- The cluster repo names the tenant's repositories and `*.upayan.dev` hostnames in its tenant
  registration. If the tenant objects to that, the fallback is a **private overlay repository** holding
  the same `deploy/<cluster>-<env>/` layout, and switching is a `repoURL` change because the layout is
  identical.
- **Contingent, and not assumed:** this model requires the tenant team to agree to host `deploy/` in
  their repos, to accept the recipients in their `.sops.yaml`, and to review rules for that path. Until
  that agreement exists, the interim is SOPS-encrypted secrets in the cluster repo, and the plan tracks
  it as an explicit open decision rather than an assumption.
- A cross-organisation write credential (image-updater committing digest pins into the tenant's repos)
  is a consequence of the bot-driven pinning the tenant already uses. It is scheduled to be replaced by
  per-repository deploy keys or by tenant CI pinning tags, so the cluster holds no write access to a
  third party's code.

## Evidence

The migration plan's Repository Ownership Model (private, not published — the options and the
evidence for them), `k8s/argocd/applications/vcap/*.yaml` (registration as it exists today),
`k8s/argocd/projects/vcap.yaml`, and `clusters/vps/tenants/vcap/README.md` (the tenant contract, once
the restructure lands).
