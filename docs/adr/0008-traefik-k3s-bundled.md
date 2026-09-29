# 0008. Use k3s's bundled Traefik, configured through a `HelmChartConfig` — do not deploy our own

- **Status:** Accepted
- **Date:** 2026-09-28

## Context

The cluster needs an ingress controller: it terminates TLS for every public host, routes to services by
`Ingress`, and hosts the KEDA HTTP interceptor's routes. k3s installs and manages one by default
(Traefik, as a packaged Helm chart in `kube-system`, reconciled by k3s itself with
`failurePolicy: reinstall`).

The question is whether to accept that or take ownership of the controller, which is the usual
recommendation for a production cluster: you want to pin the version and not have your ingress change
under you when the node's Kubernetes distribution is upgraded.

Two facts about this cluster push against the usual recommendation. There is exactly one node, so a
botched ingress rollout is a total outage with no second path in; and the whole platform is expressed as
ArgoCD Applications, so a second controller would be one more thing to keep in sync with a distribution
that is already managing one.

## Decision

**Keep the k3s-bundled Traefik, and configure it through a single `HelmChartConfig`.**

- The chart is not deployed by ArgoCD. k3s installs it and reconciles it; the cluster's only Traefik
  object in git is `k8s/platform/traefik/traefik-config.yaml` — a `HelmChartConfig` that supplies the
  extra entrypoints (metrics; formerly the Postgres TCP passthrough) and enables Prometheus metrics.
- **There is exactly one `HelmChartConfig` for a given chart name, ever.** Two would collide, so every
  Traefik setting must live in that one file — which is why the file says so at the top.
- TLS is inherited, not configured per app: `TLSStore default` makes the Origin CA wildcard the default
  certificate, and Ingresses declare no `tls:` block (ADR 0004).
- `ServiceLB` (k3s's `kube-proxy`-based load balancer) binds host ports 80 and 443 for the
  `kube-system/traefik` Service, which is how traffic reaches the controller. The auto-allocated
  NodePorts alongside them are a side effect, not a second path, and they are closed by the firewall
  rather than by removing the Service (the Service needs them).
- The Traefik version therefore tracks the k3s release — an accepted coupling, recorded in the upgrade
  policy rather than discovered during an upgrade.

## Alternatives rejected

- **Deploy our own Traefik chart through ArgoCD** (disabling the bundled one). Buys version pinning and
  portability to a non-k3s cluster. Costs a second controller competing for ports 80/443 during the
  transition, an extra upgrade surface, and the loss of k3s's automatic reconciliation — for a benefit
  that matters only if this cluster stops being k3s, which is explicitly out of scope. Kept as a
  documented future improvement.
- **A different ingress controller** (nginx-ingress, or Gateway API via Cilium). No capability this
  cluster needs that Traefik lacks, and it would mean rewriting every `Ingress` plus the KEDA
  interceptor wiring.
- **No ingress controller** — a `LoadBalancer`/`NodePort` Service per app. That exposes a port per app
  and moves routing, TLS and hostname handling into each workload.

## Consequences

- **A k3s upgrade is an ingress upgrade.** The Traefik chart version moves with the k3s version, so the
  k3s version is pinned deliberately and an upgrade is treated as a change to the ingress path, not just
  to the node's Kubernetes. That is the price of not owning the controller, and it is why the upgrade
  policy is explicit about it.
- Ingress configuration has exactly one home. That is convenient (no ambiguity about where a setting
  lives) and fragile in one specific way: adding a second `HelmChartConfig` for the same chart silently
  collides instead of merging.
- The controller's own manifests are **not** in git — k3s holds them. Only the `HelmChartConfig` is, so
  ArgoCD's `selfHeal` covers the settings but not the controller; a manual change to the controller
  itself is reverted by k3s's `failurePolicy: reinstall` instead.
- ServiceLB means the ingress is reachable on the node's address directly, so the **firewall, not the
  Service, is the access control** for ports 80/443. The port registry records the NodePorts that exist
  for that reason, and the registry check fails a change that adds an unregistered exposure.
- Traefik's CRDs (`TLSStore`, `IngressRouteTCP`) come from the bundled chart, so a future move to a
  self-managed Traefik has to install them too.

## Evidence

`k8s/platform/traefik/traefik-config.yaml` (the single `HelmChartConfig`),
`k8s/platform/traefik/tlsstore.yaml`, `inventory/ports.yaml` (the ServiceLB NodePorts and why they
close by firewall), `docs/upgrade-policy.md`, and `docs/networking.md`.
