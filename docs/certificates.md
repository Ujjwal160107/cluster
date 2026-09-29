# Certificates / TLS

Full detail: the architecture review (private, not published) §10.

## Current state

TLS terminates on Traefik with **one** certificate: a Cloudflare Origin CA wildcard served as
Traefik's default certificate (details below). Ingresses declare no `tls:` block and there are no
per-app TLS Secrets or certificates. cert-manager has been removed (2026-09-28) — its Application,
values, controllers, CRDs and webhooks are gone, and no `Certificate`/`CertificateRequest`/`Order`/
`Challenge` objects remain. Nothing in the cluster uses ACME.

Every `*.upayan.dev` host is Cloudflare-proxied with SSL mode Full (strict), Always Use HTTPS —
this part is already true and owner-confirmed current. **Min TLS version was `1.0`** (verified
directly via the Cloudflare API on 2026-09-28, imported into Terraform — `terraform/cloudflare.tf`
in the `cluster` checkout, `cluster/terraform/cloudflare.tf`) — the architecture review's §10
assumption of "min TLS 1.2" was wrong.
The owner authorised raising it to `1.2` on 2026-09-28 (task NET-005), so the Terraform now declares
`1.2`. **It is not live yet:** applying it needs a Cloudflare token with *Zone Settings: Edit*, which
this workstation does not hold, so the zone still reports `1.0` and `terraform plan` will show that
one in-place update until it is applied. Raise it, then confirm with
`openssl s_client -tls1_1` (must fail) and `-tls1_2` (must succeed) against a public host.

## Known limitation: two-level subdomains have no certificate (found 2026-09-28, S11)

Cloudflare's Universal SSL certificate for the `upayan.dev` zone covers `upayan.dev` plus **one**
wildcard level (`*.upayan.dev`). Any two-level host therefore fails TLS at the Cloudflare edge
with a handshake failure (`curl -sv` → `error:0A000410:SSL routines::ssl/tls alert handshake
failure`) — the origin is never reached, so the app itself may be perfectly healthy.

Confirmed failing hosts:

| Host | Serving app | Status |
|---|---|---|
| `qwik.dj.upayan.dev` | `learning-qwik` | backend fine, edge TLS fails |
| `react.dj.upayan.dev` | `learning-react` | backend fine, edge TLS fails |
| `api.react.dj.upayan.dev` | `learning-react` backend | edge TLS fails |
| `api.ks.upayan.dev` | `kodesphere` backend | edge TLS fails (found during the S10 cutover) |

This is why every other app here uses single-level, hyphenated API hostnames (`api-sayantani`,
`api-status-page`, `api-bitvault`, `api-rankstack`) — those are covered by the wildcard. Recorded
under S10 for `api.ks.upayan.dev` and in `changelog/2026-09.md` for the `dj` hosts. Fixing it means
either renaming the hosts to the hyphenated convention, or the S7 Origin-CA wildcard (which is
issued for the names we choose, not Cloudflare's Universal SSL constraints) plus a matching
Cloudflare edge certificate — a hostname/Cloudflare-config change needing owner sign-off, not
done here.

## Traefik default certificate: Cloudflare Origin CA wildcard (S7 — done 2026-09-28)

Because every host is Cloudflare-proxied, the origin certificate only has to be trusted by
Cloudflare — a Cloudflare Origin CA wildcard with SANs `*.upayan.dev` and `vps.upayan.dev`. That is
what Traefik serves today.

**Correction, 2026-09-28, measured live and it changes an operational assumption: the certificate in
use is valid for ONE year, not until 2041.** The re-issued certificate is
`notBefore 2026-09-28` → **`notAfter 2027-09-28`**, serial
`699090E41816073595D26CDDE0568CFE6C66BCB7`. That was verified twice — from the live
`kube-system/wildcard-upayan-dev-tls` Secret, and from the certificate the origin actually presents
over TLS (`openssl s_client -connect <origin>:443 -servername vps.upayan.dev`), which reports the same
serial. This document, `docs/architecture.md`, `AGENTS.md`, `.claude/CLAUDE.md` and the migration plan
all previously said **2041-05-06**; that is the *superseded* 2026-05-10 certificate, and every
"no renewal-failure mode" sentence was written from it. It is not true of the current one:

- the certificate must be **renewed before 2027-09-28**, and an Origin CA certificate is not renewed
  automatically — there is no ACME and cert-manager is removed by design (`adr/0004-origin-ca-tlsstore.md`);
- **a certificate-expiry alert is therefore required, not optional.** The old `tls-cert-expiring` rule
  queried cert-manager metrics that no longer exist, so it must be *replaced* by a real check rather
  than dropped — tracked as `CLEAN-002`;
- the next issuance should request a **longer validity explicitly**. The re-issue's `POST /certificates`
  produced one year; the 2026-05-10 pair was a 15-year certificate, so a long validity is available and
  simply was not requested.

**How it is wired** (implemented 2026-09-28): a `TLSStore` named `default` in `kube-system`
(`k8s/platform/traefik/tlsstore.yaml`) points at `kube-system/wildcard-upayan-dev-tls`, and that
Secret is SOPS-encrypted in git (`k8s/platform/traefik/secrets.sops.yaml`, byte-identical to the
live values). Before this the default certificate reached Traefik **by accident**:
`monitoring/grafana-tls` and `upayan-v5/upayan-v5-tls` happened to contain the same wildcard,
Traefik loaded them because those Ingresses resolved, and it then served the wildcard by SNI match
for every other `*.upayan.dev` host.

**The six broken per-app TLS references were removed** (`bandit`, `cheatsheet`, `learning-react`,
`meghmitra`, `status-page`, `upayan-web`): each Ingress named a Secret in *its own* namespace, but
those Secrets were created in `default`, so Traefik logged
`Error configuring TLS error="secret <ns>/<name>-tls does not exist"` on every reconcile and
ignored them. They now carry no `tls:` block and keep
`traefik.ingress.kubernetes.io/router.entrypoints: websecure`, so TLS still terminates on the
websecure entrypoint.

**RESOLVED 2026-09-28.** The serving certificate was replaced with one whose key was generated fresh
and never committed, and the old certificate was revoked. Details below, kept because the reasoning is
what the rotation runbook still relies on.

**Correction (2026-09-28, second revision): the key of the certificate in use *was* committed.**
This section has now been wrong twice, so here is the measured state rather than a conclusion. There
are two Origin CA pairs involved:

| Pair | Certificate | Private key |
|---|---|---|
| 2025-03-29 (`notBefore 2025-03-29`, public key `sha256 01e6a788…`) | in git history (`k8s vm1/v2/cloudflare-key.pem`) | **not in use** — no live Secret matches it. It is also **not among the zone's active certificates** (checked through the Origin CA API on 2026-09-28), so there was nothing left to revoke for it. |
| 2026-05-10 (`notBefore 2026-05-10`, serial `034BB2554CEC79D74C3C6109C42B23DEFEB53D5F`, SANs `*.upayan.dev`, `vps.upayan.dev`, valid to 2041) | served the origin from 2026-05-10 until 2026-09-28, then **revoked** (id `18815063215507537879465766570076134496689012063`; the zone's active certificates went 14 → 13) | **was committed in plaintext** at `k8s/traefik/key.pem` until it was deleted on 2026-09-28 — which is why this pair was re-issued with a fresh key rather than simply re-stored |
| **2026-09-28 → 2027-09-28** (serial `699090E41816073595D26CDDE0568CFE6C66BCB7`, SANs `*.upayan.dev`, `vps.upayan.dev`) | **this is what the origin serves right now** — verified from the live Secret *and* from the certificate presented over TLS | fresh keypair generated locally, **never committed**; it exists only inside the SOPS-encrypted Secret. Public key `30b06d23…`, deliberately different from the committed `33ef16eb…`. **One-year validity — see the correction above.** |

The 2026-05-10 pair was committed by `9d8425d` ("Remove cert-manager integration and add Traefik TLS
setup", 2026-05-10) alongside `cert.pem` and two helper scripts, and it is the pair the origin has
been serving since. Verified by comparing public-key fingerprints, not by assumption:
`openssl pkey -in k8s/traefik/key.pem -pubout | openssl pkey -pubin -outform der | sha256sum` gave
`33ef16eb7a685114b2523dee013d947fbcb49e578c4da2501b35ef285acc5e60`, and the same pipeline over the
live `Secret/wildcard-upayan-dev-tls` in `kube-system` gave the **same digest**. The same key is also
inside the SOPS-encrypted Secret (same digest), so deleting the plaintext file lost nothing — it is
still served from the encrypted copy.

So the earlier sentence here ("the rotation already happened") was wrong for the pair that matters:
the certificate in use has a **publicly known private key**. Deleting the file does not fix that —
it is still in git history. The fix is to **re-issue the certificate with a brand-new key** and then
revoke the old one, which is an owner action (Cloudflare Origin CA).

**S7 status, corrected 2026-09-28.** All three items below are resolved; this document still listed
them as outstanding *after* they were done, which is the same drift that produced the 2041 error. The
changelog entries are the record (S7 closed at ~03:40 IST on 2026-09-28):

- **Re-issue the serving Origin certificate with a new key, then revoke the old one — DONE.** Issued
  through the Origin CA API, deployed, verified on three hostnames, then the old certificate was
  revoked. Re-verified live on 2026-09-28: the origin presents serial `699090E4…`, expiring
  **2027-09-28**.
- **Revoke the leaked 2025 Origin certificate — nothing to revoke.** It is not among the zone's active
  certificates. Eleven other unused certificates from earlier rotations remain in the zone; they are
  inert and were left listed for the owner to decide on.
- **Traefik's `web` entrypoint permanent redirect to `websecure` — decided against** (owner,
  2026-09-28). Cloudflare already answers every host with `301` to HTTPS (verified on five), so the
  observable outcome already exists; Traefik is a single replica, so the change would cost a brief
  cluster-wide ingress blip for no measurable gain. Closed, not pending.

What remains is not a task but a **deadline**: renew before **2027-09-28**.

**Leftover `*-tls` Secrets: done 2026-09-28.** The cluster went from 22 `kubernetes.io/tls` Secrets
to exactly **2**: `kube-system/k3s-serving` (k3s-managed, left alone) and
`kube-system/wildcard-upayan-dev-tls` (the default certificate). The wildcard duplicates in
`default` were byte-identical to the one now in git; the rest were certificates for retired or
renamed apps (`kargo-*`, `kodesphere`, `learning-react`, `shivaay-web`, `smart-home-*`) plus
unreferenced ones. `argocd` and `grafana` — the last Ingresses with their own certificates
(argocd's a cert-manager-issued Let's Encrypt one) — now take the default certificate too, which
is what made cert-manager removable.

**Every host this cluster serves is Cloudflare-proxied** — resolution returns `2606:4700::/32` for
all of them — so an Origin CA certificate is correct throughout. Note `sayantani.upayan.dev` and the
`upayan.dev` apex do **not** point at this cluster (they resolve to Vercel), which is why
`sayantani.upayan.dev` presents Vercel's redirect rather than anything from `k8s/` (so the
`sayantani.upayan.dev` rule in `k8s/apps/cheatsheet` routes nothing).

Internal TLS is not added — single node, pod network never leaves the host.

### vcap Postgres TLS (paired with S6's network lockdown)

vcap Postgres stays public, so it gets server-side TLS with a **private CA** (5-year leaf; CA +
key stored in SOPS, the CA cert handed to devs). Clients connect to the DNS-only (grey-cloud) name
`db.upayan.dev` with `sslmode=verify-full sslrootcert=vcap-db-ca.crt`. Chosen over a Let's Encrypt
cert to avoid an ACME/cert-manager dependency and Postgres reload-on-renew machinery. Expiry is
tracked in `../inventory/ports.yaml` and exported by the backup script as a
`vcap_db_cert_expiry_timestamp` textfile metric, alerting under 60 days.

### Monitoring hooks

No cert-manager expiry metrics exist any more (cert-manager is removed, nothing uses ACME), and the
`tls-cert-expiring` rule that queried them is therefore dead. A **real** expiry check is required
instead, because the current certificate expires **2027-09-28** — this is a dated obligation, not a
theoretical one.

The replacement should measure what is actually served: a Traefik/blackbox
`ssl_earliest_cert_expiry`-style probe against a public host, alerted with enough margin (≥60 days) to
cover the owner action, since issuance needs a Cloudflare token with Origin CA permission. A "yearly
manual doc check" is not sufficient — there is no mechanism that makes anyone perform it. Tracked as
`CLEAN-002`, whose original wording ("replace it with … or **drop it**") this supersedes: dropping it
is no longer acceptable.

## Related

- [`runbooks/rotate-certificates.md`](runbooks/rotate-certificates.md) — the reissue/rotation procedure, once S7 lands
- [`secrets.md`](secrets.md) — certs and CA keys are stored as SOPS Secrets
- [`networking.md`](networking.md) — the public-Postgres decision this TLS design supports
