# 0007. Scale-to-zero with KEDA and the KEDA HTTP add-on

- **Status:** Accepted
- **Date:** 2026-09-28

## Context

One node with a fixed amount of RAM, running a long tail of apps that are genuinely idle most of the
time — a portfolio site, demo apps, a couple of services with a handful of users. Left always-on they
consume memory permanently to answer perhaps a few requests a day, and on a single node the memory they
hold is the memory the important workloads cannot use. The node runs close to its limits as it is.

The constraint that rules out the obvious answer: `HorizontalPodAutoscaler` cannot scale **from** zero.
It needs a running pod to measure, so the smallest state it can reach still costs memory.

## Decision

**KEDA, pinned at 2.21.0, with the KEDA HTTP add-on for request-driven scaling, drives idle apps between
zero and one replica.**

- The **HTTP add-on** is what makes this usable for web apps: an interceptor holds the incoming request,
  asks the scaler to bring the target up, and then proxies it. No request is lost to a cold start.
- Apps that are not request-driven but are time-driven (a cron-shaped workload) use a KEDA cron trigger
  instead.
- **ArgoCD ignores `/spec/replicas` on the affected Deployments.** Without that, the GitOps loop and the
  scaler fight over the replica count and the app flaps.
- Scaled-to-zero apps run on the **`low-priority`** class: when the node is under memory pressure the
  kubelet reclaims them before anything that is meant to stay up.
- The platform component versions are pinned (chart `2.21.0`), and the add-on runs as separate
  Applications (`keda`, `keda-add-ons-http`), with the public hosts and their backend services in
  `keda-add-ons-http-routes` — so the routing table for scaled apps is reviewable in one file.

## Alternatives rejected

- **Always-on replicas with small limits.** Simplest, and rejected because the memory cost is permanent
  and the benefit is a faster first request.
- **Plain `HorizontalPodAutoscaler`.** Cannot scale from zero, which is the entire point.
- **A serverless platform (Knative, OpenFaaS).** A much larger footprint — its own ingress,
  autoscaler and queue proxy per pod — to solve a problem the HTTP add-on already solves at a fraction
  of the size on one node.
- **Scaling to zero by hand or from CI on a schedule.** No way to wake on a request, so a visitor gets a
  503 instead of a cold start.

## Consequences

- **Cold-start latency is real and by design.** The first request to an idle app waits for a pod to
  start; the interceptor absorbs that wait rather than failing the request, which turns a slow response
  into a successful one.
- **"Healthy" stops meaning "working".** A fully scaled-down app reports `Healthy` with **zero pods**, so
  ArgoCD health is not evidence the app serves traffic. The host sweep (does every Ingress host return
  its documented status) is the check that actually proves it — and it is why that sweep is part of the
  change-validation routine. A latent failure can hide here indefinitely: one app was believed healthy
  while its persistent volume pointed at a deleted Hetzner volume, because it never scaled up.
- Every affected Deployment needs the `ignoreDifferences` entry, so the pattern has to be copied when
  adding an app rather than discovered later as unexplained flapping.
- **KEDA's metrics API server is an aggregated APIService, which is a cluster-level failure mode.**
  When it is briefly unreachable, the namespace controller fails to enumerate API groups and then
  **does not retry**, leaving a namespace stuck in `Terminating` with
  `external.metrics.k8s.io/v1beta1: stale GroupVersion discovery`. That has happened five times on this
  cluster. The remedy is documented (prove the namespace empty, then empty its finalizers through the
  `/finalize` subresource), the metrics apiserver runs two replicas, and the underlying "controller gives
  up rather than retrying" behaviour is recorded as worth a permanent fix.
- KEDA becomes load-bearing for a large share of the apps, so its upgrade is a deliberate, tested change
  rather than a version bump.

## Evidence

`k8s/argocd/applications/platform/{keda,keda-add-ons-http,keda-add-ons-http-routes}.yaml`,
`k8s/platform/keda-add-ons-http-routes/ingress.yaml` (the scaled hosts),
`k8s/platform/priority-classes/priorityclass.yaml`, the `ignoreDifferences` block in
`k8s/argocd/applicationsets/apps.yaml`, and the namespace-wedge entries in `changelog/2026-09.md`.
