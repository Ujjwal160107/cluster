# 0004. One Cloudflare Origin CA certificate served through a Traefik `TLSStore` (no cert-manager)

- **Status:** Accepted
- **Date:** 2026-09-28

## Context

Every public hostname on this cluster is Cloudflare-proxied, so Cloudflare terminates the client-facing
TLS connection and the origin only ever needs to satisfy Cloudflare itself. Traditionally that still
meant ACME certificate management on the origin: cert-manager, an issuer, a `Certificate` per host, a
renewal loop, and a failure mode that shows up as a certificate expiring because a renewal silently
failed.

There is also a hard constraint on this cluster: it is a single node. An expired certificate cannot be
worked around the way a failed deployment can, and there is no second node to serve traffic while the
renewal is fixed.

The immediate trigger for this decision was worse than an expired certificate. A private key that was
actively being served had been committed to git on 2026-05-10 and stayed there for four and a half
months, unnoticed, until a gitleaks scan found it — while a per-host `Certificate` resource was
simultaneously pointing at hand-made secrets. The TLS setup had more moving parts than the situation
needed, which is what made that invisible.

## Decision

**One Cloudflare Origin CA wildcard certificate, served as Traefik's default certificate. No ACME, no
per-app certificates, no cert-manager.**

- The certificate covers `*.upayan.dev` and `vps.upayan.dev`. **Validity: 2026-09-28 → 2027-09-28**
  (one year). This record originally said "until 2041-05-06", which was the *predecessor*
  certificate's date — see the correction under *Consequences*, because that error had an operational
  consequence: it made a hand-run annual renewal look like a 15-year non-problem.
- It is stored as `kube-system/wildcard-upayan-dev-tls`, SOPS-encrypted in
  `k8s/platform/traefik/secrets.sops.yaml` (ADR 0002) — the private key is never committed in plaintext.
- `TLSStore default` in `kube-system` (`k8s/platform/traefik/tlsstore.yaml`) makes it Traefik's default,
  so **Ingresses declare no `tls:` block at all** and inherit it.
- `cert-manager` was removed entirely on 2026-09-28: its Application, values, controllers, CRDs,
  webhooks, and every `Certificate`/`CertificateRequest`/`Order`/`Challenge` object.
- The previously served certificate was **re-issued with a key that was never committed, and the old
  one revoked**, because its private key had been public.

## Alternatives rejected

- **cert-manager with Let's Encrypt.** Renewal machinery for every host, for hostnames Cloudflare
  already terminates — and the thing it would renew is one wildcard, since a `TLSStore` default serves
  every Ingress. The certificate it replaced was a Let's Encrypt one valid to 2026-11-22 that would
  have had to renew, so *some* renewal process was needed either way; the question was only which one.
  **This bullet used to claim a 15-year Origin CA certificate "does not need them", and that turned out
  to be wrong** (see *Consequences*) — the reason to prefer the Origin CA is the trust anchor for a
  Cloudflare-proxied origin, not the absence of an expiry.
- **A `Certificate` resource per app.** Many objects and many renewals, all for hostnames Cloudflare
  already terminates.
- **Cloudflare proxy without origin TLS** (Full, not Full-strict). Traffic between Cloudflare and the
  origin would be plaintext, which is unacceptable for a login-bearing origin.
- **Self-signed origin certificates.** Requires distributing a trust anchor to Cloudflare; the Origin CA
  is built for exactly this and is free.

## Consequences

- **One object to rotate, so a rotation touches every host at once.** That is the trade for having no
  renewal *loop* — but not for having no renewal: the certificate must be reissued by hand before
  **2027-09-28**, which is why its issuance is a documented, token-gated runbook rather than an
  automated process.
- **An Ingress must not declare `tls:`.** The referenced per-app secret does not exist, so the
  annotation-free form is the correct one; six stale references were removed when this landed.
- **Two-level hostnames cannot work.** Cloudflare's Universal SSL covers the zone apex plus one wildcard
  level, so any host like `a.b.upayan.dev` fails the TLS handshake **at Cloudflare's edge** — the origin
  is never reached, so the app can be perfectly healthy and still be unreachable. The fix is a
  single-level hyphenated name (the convention everywhere else) or an edge certificate. This is a
  Cloudflare constraint and cannot be fixed from the origin.
- **A certificate-expiry alert is required, not optional.** An earlier version of this record said an
  expiry alert "is meaningless here and is scheduled for removal (`CLEAN-002`)". That was written from
  the 2041 assumption and is wrong: there is a real date to watch, so `CLEAN-002` must **replace** the
  dead cert-manager-based rule with a real expiry metric, not delete it. Deleting it with no
  replacement turns a managed expiry into an unannounced cluster-wide outage.
- **Correction, 2026-09-28 — the validity in this record was wrong.** It (and `docs/certificates.md`,
  `docs/architecture.md`, `AGENTS.md`, `.claude/CLAUDE.md` and the migration plan) stated
  "valid to 2041-05-06" as the *current* certificate. Measured live, what the origin serves is
  `notBefore 2026-09-28 → notAfter 2027-09-28`, serial `699090E41816073595D26CDDE0568CFE6C66BCB7`: the
  reissue requested **one year**, where its predecessor had fifteen. The 2041 date belonged to the
  revoked predecessor — and neither the doc nor the review noticed the change, which is exactly the
  failure mode this record exists to prevent.
  **The generalisable lesson: an expiry claim in prose is a claim about one specific certificate, and
  every reissue invalidates it. Read the date off the certificate, never off the documentation.**

## Evidence

`k8s/platform/traefik/{tlsstore.yaml,secrets.sops.yaml,traefik-config.yaml}`, `docs/certificates.md`
(including the two-level-hostname limitation), and the S7 entries in `changelog/2026-09.md` that record
the re-issue, the revocation and the gitleaks finding.
