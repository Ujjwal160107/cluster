# Runbook: rotate a certificate

Two certificates exist or are planned: the **Cloudflare Origin CA wildcard** that serves every
`*.upayan.dev` host (live), and a **private-CA leaf for vcap Postgres** (planned, S6 — not
implemented, see the section at the end). Design background: [`../certificates.md`](../certificates.md).

## Cloudflare Origin CA wildcard — live, and overdue for rotation

**Current state, verified live 2026-09-28:** `TLSStore default` in `kube-system` points at Secret
`wildcard-upayan-dev-tls`, which is SOPS-encrypted in `k8s/platform/traefik/secrets.sops.yaml` and
applied through a ksops generator (`secret-generator.yaml`). The origin serves serial
`699090E41816073595D26CDDE0568CFE6C66BCB7`, SANs `DNS:*.upayan.dev, DNS:vps.upayan.dev`,
**valid 2026-09-28 → 2027-09-28 — one year**. The `034BB255…` certificate this paragraph used to name
is that pair's predecessor: it was valid to 2041 and has been revoked. The "valid to 2041" figure
belonged to it, not to what the origin serves now.

> **Renew before 2027-09-28.** Nothing renews this automatically. `CLEAN-002` must add a real expiry
> check (a Traefik/blackbox `ssl_earliest_cert_expiry`-style metric, alerting at least 60 days out)
> rather than only retiring the dead `tls-cert-expiring` rule — dropping that rule without a
> replacement would leave a dated, cluster-wide outage with no warning.
>
> **When you do renew: request a longer validity explicitly.** The re-issue's `POST /certificates`
> produced one year; the 2026-05-10 pair was a 15-year certificate, so a long validity is available
> and simply was not asked for. The install procedure is unchanged (below), and the SOPS re-encrypt is
> the only repo-side step.

**Done 2026-09-28.** Reissued with a fresh key (serial `699090E41816073595D26CDDE0568CFE6C66BCB7`,
valid to 2027-09-28) and revoked the old one. Two things learned that the next rotation should reuse:

- **The dashboard path is behind MFA; the API path is not.** `POST /certificates` with a token carrying
  *Zone → SSL and Certificates → Edit* issues the certificate in one call.
- **`csr` must be the PEM text, not base64 DER.** Base64 DER returns
  `1007 CSR parsed as empty` — which reads like a malformed CSR but is actually an encoding mismatch.
- List and revoke are **zone-scoped**: `GET /certificates?zone_id=…`, `DELETE /certificates/<id>?zone_id=…`.
  Both need the **full 47-character id**; a truncated one fails with
  `1101 Failed to read certificate from Database`.

**Why this mattered more than documentation:** the superseded certificate's **private key was
public** — committed as `k8s/traefik/key.pem` from 2026-05-10 until it was deleted on 2026-09-28, and
still in git history today. Deleting the file did not undo that, and that certificate stayed valid
until 2041, which is why the only real fix was a **reissue with a fresh key** — revoking without
reissuing just leaves nothing to serve. **That rotation is done** (2026-09-28, old certificate
revoked); the value of this section now is the shape of the procedure, not an outstanding task.

### 1. Issue a new certificate with a new key

Dashboard: **SSL/TLS → Origin Server → Create Certificate**. Hostnames:
`*.upayan.dev` **and** `vps.upayan.dev` (the current cert carries both). Keep the key on the machine
that will run SOPS.

Prefer **1 year over the current 15**: the whole reason this certificate is being replaced is that a
long-lived key leaked, and the `tls-cert-expiring` alert plus this runbook make a yearly rotation cheap.

Via the API instead (needs a token with **Origin CA: Edit** — that permission is what I could not find
locally, which is why this is an owner action):

```
POST https://api.cloudflare.com/client/v4/certificates
     Authorization: Bearer <token>
     {"hostnames":["*.upayan.dev","vps.upayan.dev"],"requested_validity":365,"request_type":"origin-rsa","csr":"<base64 CSR>"}
```

### 2. Store it

```bash
# sops finds the offline age key by default; set SOPS_AGE_KEY_FILE only if yours lives elsewhere
sops k8s/platform/traefik/secrets.sops.yaml
# Secret `wildcard-upayan-dev-tls` in kube-system, keys `tls.crt` and `tls.key` in `data:` (base64).
# There is no separate origin-cert.sops.yaml — an older version of this runbook named one that never
# existed, which would have written a Secret nothing reads.
```

### 3. Commit, push, sync

```bash
git commit -am "rotate: Cloudflare Origin CA wildcard (new key)" && git push origin main
kubectl -n argocd annotate app traefik-config argocd.argoproj.io/refresh=hard --overwrite
```

### 4. Restart Traefik, and confirm only the NEW certificate is loaded

**This step was missing until 2026-09-28, and without it a rotation is only half-effective.**
Traefik's certificate store is **additive**: replacing the Secret makes Traefik *add* the new leaf but
does **not** drop the one it already holds. Measured after the S7 reissue — Traefik reported **two**
loaded certificates for the same SAN set: the new one (expiring 2027-09-28) and the **revoked**
predecessor (expiring 2041-05-06) whose private key had been public. So until the process restarted, a
certificate with a compromised key stayed loaded and remained a candidate to serve — precisely what the
rotation existed to remove. Cloudflare validates the origin by chain (Full *strict*), not by key, so a
chain-valid but compromised certificate is still accepted at the edge.

```bash
kubectl -n kube-system rollout restart deploy/traefik
kubectl -n kube-system rollout status  deploy/traefik --timeout=180s
```

That is a permitted break-glass action (restart after a Secret commit). It costs a brief ingress blip —
Traefik is a single replica, so nothing listens on 80/443 for a few seconds — so do it deliberately.

Then confirm exactly **one** certificate is loaded:

```bash
kubectl -n monitoring exec deploy/prometheus -c prometheus -- \
  wget -qO- --post-data='query=min by (serial) (traefik_tls_certs_not_after)' \
  http://localhost:9090/api/v1/query | python3 -m json.tool | grep -E 'serial|value'
# expect: ONE series, carrying the NEW serial.
#   two series  -> the old leaf is still loaded (restart again), or the Secret never changed
#   no series   -> Traefik is not exporting certificate metrics at all; that is its own problem
```

`min by (serial)` rather than the bare metric on purpose: Traefik exports one series per loaded
certificate and the pod is scraped twice (`job=traefik` and `job=kubernetes-pods`), so the raw query
returns duplicates.

Finally, re-check a few public hosts — the same sweep the change-validation routine uses:

```bash
for h in bandit.upayan.dev ks.upayan.dev status-page.upayan.dev api.upayan.dev; do
  printf '%-30s %s\n' "$h" "$(curl -s -o /dev/null -w '%{http_code}' "https://$h")"
done
```

### 5. Verify the **origin** serves it — before revoking anything

```bash
echo | openssl s_client -connect 138.201.157.147:443 -servername ks.upayan.dev 2>/dev/null \
  | openssl x509 -noout -serial -dates -ext subjectAltName
# expect: the NEW serial, both SANs, the new dates
```

Then confirm a public host still works end to end:
`curl -s -o /dev/null -w '%{http_code}\n' https://argocd.upayan.dev` (any host). A **`526`** from
Cloudflare means the edge could not validate the origin certificate — i.e. the Secret did not apply,
or the key and certificate do not match. That is the signal to fix before going further, not after.

### 6. Only now revoke the old certificate

Dashboard: **SSL/TLS → Origin Server**, revoke serial `034BB255…`. Via the API:
`DELETE /certificates/<id>` (same Origin CA permission). Revoking first would leave the origin serving
a certificate Cloudflare refuses.

## Private CA leaf for `db.upayan.dev` (vcap Postgres TLS) — **not implemented**

This section describes work that does not exist yet, so do not follow it expecting anything to happen:

- Postgres runs with **`ssl = off`** today (verified on `vcap-backend-staging-postgres`, 2026-09-28);
  the exposure of 5432/5433 is a deliberate owner decision with TLS as part of the S6 work.
- `db.upayan.dev` **does** resolve (proxied through Cloudflare), so the DNS half is ready — but nothing
  serves TLS on that name yet.
- The `vcap_db_cert_expiry_timestamp` metric and its 60-day alert, which an earlier version of this
  runbook cited as existing, **do not exist anywhere in this repo**. Whoever implements S6's Postgres
  TLS must create that metric and alert in the same change, or the leaf will silently expire.

When S6 lands, the shape is: regenerate the leaf from the existing private CA (never the CA itself
unless it is compromised — that invalidates every vcap dev's `sslrootcert`), store it as a SOPS Secret
mounted `0600` in both environments, roll the Postgres pods, and validate with
`psql "host=db.upayan.dev port=5433 sslmode=verify-full sslrootcert=vcap-db-ca.crt" -c '\conninfo'`.
