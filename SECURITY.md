# Security policy

This repository describes a live, internet-reachable cluster, and it is published. Treat it as
security-relevant: a leak of a credential, a manifest that exposes something, or an answer here that
makes an exposure worse all count.

## Reporting a vulnerability

**Use GitHub private vulnerability reporting.** Go to the repository's **Security** tab → **Report a
vulnerability** (this maps to GitHub's private advisory flow, `POST /repos/<owner>/<repo>/security-advisories`).
That is the supported route: it is private, it notifies the maintainer, and it needs no address to be
published in this file.

Do **not** open a public issue, pull request or discussion for a vulnerability, and do not include a
live credential in anything you file — not even in the private advisory. If a credential may have been
exposed, say *where* it is, not *what* it is.

Please include, where you can:

- what the issue is and the impact you believe it has;
- the affected hostname, path or resource (for example an Ingress host, a `k8s/` path, or a port);
- how to reproduce it, or the evidence you have (a response header, a log line, a probe result);
- whether the finding is already public.

## What to expect

- **Acknowledgement** within a few days of the report reaching the private advisory.
- **An assessment** with either a fix plan and a rough timeline, or an explanation of why it is not a
  vulnerability (for example, if it is a known, documented trade-off — [`docs/ports.md`](docs/ports.md)
  and [`docs/networking.md`](docs/networking.md) record the ones that currently exist on purpose).
- **Credit** in the advisory once a fix is out, if you want it.

## Scope

In scope:

- the k3s cluster and the workloads it runs, reached via `*.upayan.dev`;
- this repository and the resources it establishes (Ingress, firewall, RBAC, NetworkPolicy, Secrets);
- exposure of secrets or credentials, whether in this repository's tree, its history, or a running
  workload.

Out of scope:

- **Denial of service and volumetric attacks.** The cluster is a single node with no upstream
  scrubbing; a flood is not a finding.
- **Findings already documented as known and accepted** — the port registry and the ADRs
  ([`docs/adr/`](docs/adr/README.md)) name them and their rationale.
- **Automated-scanner output with no demonstrated impact.**
- Anything that requires you to already hold valid production credentials.

## A note on this cluster's design

Several things that would be findings elsewhere are deliberate here and are recorded in the docs
rather than silently: the host is a single node, the Hetzner firewall is currently permissive while
the port registry states exactly what is and is not reachable, and the legacy Postgres ports are
closed rather than hardened. Read [`docs/README.md`](docs/README.md) before reporting one of those —
and if the documentation is wrong about the live state, that is itself worth reporting.
