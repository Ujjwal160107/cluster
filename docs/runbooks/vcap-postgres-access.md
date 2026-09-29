# Runbook: VCAP Postgres external access (15432 / 15433)

How the tenant's developers reach the VCAP dev and staging Postgres instances — and, plainly, that
they **cannot yet**.

## Status: open since 2026-09-29

**`15432` (dev) and `15433` (staging) are live, TLS-only, and verified end-to-end from a client** —
the contract below is what is enforced, not an aspiration. `5432`/`5433` are closed **permanently**:
their firewall rules were removed, so nothing can serve them even by accident.

Three things to know before the first connection: the application runs as a non-superuser role; the
**person** roles are **read-only** (SELECT and nothing else); and the bootstrap superuser is refused
over TCP entirely — operator work happens through `kubectl exec … psql`. ADR
[`0009`](../adr/0009-vcap-postgres-public-ports.md) records the decision and its status.

## The contract (once open)

| | Dev | Staging |
|---|---|---|
| `host` (for the TLS name) | `pg-dev.upayan.dev` | `pg-staging.upayan.dev` |
| `hostaddr` (what is actually dialled) | the node's public address | same |
| Port | **15432** | **15433** |
| TLS | required | required |
| Verification | `sslmode=verify-full` recommended, `verify-ca` the minimum, against the VCAP Postgres edge CA | same |
| Login | a **per-person, non-superuser** role | same |
| Superuser | pod network only — never over this path | same |

`5432` and `5433` are **not** part of the contract: they are what the ports are moving *away from*, and
they are closed (ADR 0009 is explicit that the port move is not itself a security control — it stops
default-port scanning finding the databases and makes the exposure a decision rather than an
inherited accident).

### Connecting

The client is given a **name for the certificate** and an **address to dial**, separately:

- `host=pg-<env>.upayan.dev` is what libpq puts in the TLS SNI and what the certificate is verified
  against. **It intentionally has no DNS record** — it is not meant to resolve, and creating one would
  be against this repository's rule that DNS records are adopted from the live zone rather than
  hand-written.
- `hostaddr=<node public address>` is the address actually dialled.

That split is what makes the routing work: the edge routes on a **specific SNI**, and a client that
connects by bare IP sends none, so Traefik would fall back to the cluster's default certificate — the
`*.upayan.dev` wildcard — which does not chain to the edge CA. Naming the SNI lets Traefik present the
edge's own leaf instead, with nothing else about the cluster's TLS changed.

```bash
psql "host=pg-dev.upayan.dev hostaddr=<node public address> port=15432 \
      dbname=<your db> user=<your role> sslmode=verify-full sslrootcert=/path/to/vcap-postgres-edge-ca.crt"
```

- `verify-full` checks the chain **and** that the certificate carries `pg-dev.upayan.dev`, which it
  does. `verify-ca` checks only the chain and also works (and is the fallback if your client cannot
  set `host` and `hostaddr` separately). Do **not** use `sslmode=require` (it accepts any certificate,
  so it is not verification) and do not disable TLS.
- Your role is **not** a superuser. It can reach only the database(s) it was granted; `CREATE
  DATABASE`, `CREATE ROLE` and cross-database reads are expected to fail.

### The CA certificate

Public, and safe to copy from here (it is a certificate, not a key):

```pem
-----BEGIN CERTIFICATE-----
MIIDVDCCAjygAwIBAgIUHfY5BjlfVIEY6Qck0JPFQNJHeSgwDQYJKoZIhvcNAQEL
BQAwQjErMCkGA1UEAwwiVkNBUCBQb3N0Z3JlcyBlZGdlIENBICh1cGF5YW4uZGV2
KTETMBEGA1UECgwKdXBheWFuLmRldjAeFw0yNjA5MjkxNzE2NDJaFw0zNjA5MjYx
NzE2NDJaMEIxKzApBgNVBAMMIlZDQVAgUG9zdGdyZXMgZWRnZSBDQSAodXBheWFu
LmRldikxEzARBgNVBAoMCnVwYXlhbi5kZXYwggEiMA0GCSqGSIb3DQEBAQUAA4IB
DwAwggEKAoIBAQDKUPMI0ghZX2y8Ueicm+Vg+60X7x0DKTrk3sBPGP9L6z3onfu4
OkJskueFZH95Ce5I1z6DWLVUzgKAiP/ybxKK/aITVjsRFhjUHc3yM71nVVGx49Nb
Pa3OKE1ZpVQtQkyrTSQxt7PucodjCtGTGzTL9G2EOcdFRIIB7bQS1y0HZ0pSCcEP
sADqmSz3bUvlYYziYe0EwdsFOx6pnjSZvqc6wOfQA2Vew3Jox85FKt4vr/KXk9cD
M+m3jfz+V6KBvfzZ07trg8U8Atj7nbc3WxiHIA8+3AJDjiSryF1E7LqQLqLVSHuP
XRvjZhVgvY7Dr5FsPFrqNmmS9Gp09DLeedpBAgMBAAGjQjBAMA8GA1UdEwEB/wQF
MAMBAf8wDgYDVR0PAQH/BAQDAgEGMB0GA1UdDgQWBBT+/pP3XIczrXYt3fRNN3GG
0EifNDANBgkqhkiG9w0BAQsFAAOCAQEAqWrO/A6zVEQITZcEABjUfEkLZfSaV0Wd
Q2u5wsz0PfGErvDHwfIe+vddzBCQmA0usj1oGeUpU0auxtaSR6RfBMCJJIYOkk3v
AOZudvdElM+H5OEu00AQOV2Bk47ecJCDjYYhyDH/9oE/CShLKXmnfihc/V0tN1tp
iGanpr0rJLc3jFiSEAPMfEeVHOCjLQC23Nhve/vYNCxPAdusooAkUE1Ghr2tHswh
h3nU8ReH7Klm/+v9ZjAcPIe5ql75+YnufJ9xgH3kgNWasPQ3rKqqRIPJGxFEhyrd
qv73zwdqKx0GmTjeQcjcszfVkO2G9grEEuUfRM6ZBEm2vJeab7Qe6g==
-----END CERTIFICATE-----
```

## Requesting a role

Names and passwords are never committed — the owner keeps the list privately (OD-15).

1. Ask the cluster owner (out of band) for access, naming:
   - the **environment** (dev or staging);
   - which **database(s)** you need;
   - whether you need write access or read-only.
2. The owner creates a per-person, non-superuser role in that instance and sets its password. The
   password is shared with you through the password manager, per person — **never** in chat, email or
   git.
3. The owner hands you the **edge CA certificate** the same way. Keep it with the client config.
4. The role is per person on purpose: it can be revoked individually, and the audit trail in
   `pg_stat_activity` / the server log names a person rather than "the shared account". Do not share
   your role or its password.

There is no self-service path. The superuser credentials are not handed out, and the application
itself runs as a non-superuser role after P2-08.

## Operating the database (the role model)

Since 2026-09-29 the application no longer logs in as the bootstrap superuser. What exists, and what
each thing is for:

| Role | Kind | Purpose |
|---|---|---|
| the bootstrap role (`POSTGRES_USER`) | superuser, **socket only** | `kubectl exec … psql` for operator work and for anything needing superuser (creating extensions, for instance). It is refused over TCP by `pg_hba`. |
| `vcap_app` | LOGIN, NOSUPERUSER, NOCREATEROLE, NOCREATEDB | the application. It **owns** the database and every object in `public`, so migrations and DDL work without superuser. |
| `vcap_people` | NOLOGIN group | the named people. `SELECT` by default, no writes. |
| one LOGIN role per person | member of `vcap_people` | handed out individually so access can be revoked individually. |

**Adding a person** (the password never goes through git, chat or email — hand it over in the password
manager):

```bash
kubectl -n vcap-dev exec -it deploy/vcap-backend-dev-postgres -- \
  psql -U "$POSTGRES_USER" -d vcap -c "CREATE ROLE <name> LOGIN NOSUPERUSER NOCREATEROLE NOCREATEDB PASSWORD '<generated>' VALID UNTIL '<date>'"
kubectl -n vcap-dev exec -it deploy/vcap-backend-dev-postgres -- \
  psql -U "$POSTGRES_USER" -d vcap -c "GRANT vcap_people TO <name>"
```

`SELECT` is granted through `vcap_people` plus `ALTER DEFAULT PRIVILEGES FOR ROLE vcap_app`, so tables
created by a later migration are readable automatically. Writes are granted per person and per
environment only if VCAP asks.

**Two traps worth knowing before you touch this:**

- **`REASSIGN OWNED` does not work here.** The bootstrap role owns `information_schema` and the
  `pg_catalog`-side `plpgsql` extension, which PostgreSQL refuses to reassign —
  *"cannot reassign ownership of objects owned by role … because they are required by the database
  system"*. Ownership must be moved **per object** (`ALTER TABLE/SEQUENCE/VIEW/ROUTINE/TYPE/DOMAIN …
  OWNER TO`). A table's composite row type cannot be `ALTER TYPE`d at all — use `ALTER TABLE`, and be
  aware that under `ON_ERROR_STOP` one such statement aborts the rest of the batch.
- **The policy is a file, not a flag.** `pg_hba.conf` is installed *into the data directory*, so
  setting the chart's `postgres.pgHba.mode` to `off` does **not** restore the previous behaviour — the
  restrictive file stays in force. `mode: "default"` is the revert state; it writes the permissive
  policy back explicitly.

## Rotating the TLS leaf

The edge TLS certificate is a leaf signed by a **private CA whose key lives only in the owner's
password manager and offline medium** (never in git, never on the node). The leaf is committed
SOPS-encrypted and applied by ArgoCD as the in-cluster Secret `vcap-postgres-edge-tls`, from
`k8s/apps/vcap/edge/<env>/secrets.sops.yaml`.

**Leaf renewal** (a new certificate, same CA — this is the routine rotation):

1. On the workstation, generate a key and CSR for the leaf, signed by the private CA (the CA key is
   read from the password manager only for this step; never copy it to disk or scrollback).
2. Replace the `tls.crt` / `tls.key` entries in `k8s/apps/vcap/edge/<env>/secrets.sops.yaml` and
   re-encrypt with `sops`.
3. Commit and push; ArgoCD applies the Secret on the next sync (or annotate the app for a hard
   refresh).
4. Roll the edge so the connections are served the new leaf — the IngressRouteTCP/Traefik data plane
   is cluster-owned (P2-05/P2-08); a `kubectl rollout restart deploy/traefik -n kube-system` in a
   window is the documented way if the leaf is loaded at start.
5. Verify from the node (works with the ports still closed):
   `openssl s_client -connect 127.0.0.1:15432 -servername pg-dev.upayan.dev -CAfile ca.crt
   -verify_return_error` must verify and show the new leaf's validity dates. From an ordinary host,
   add `-starttls postgres` and dial the public address once the port is open.

**CA rotation** (the CA key itself is being replaced) is a different, larger operation: every client
is pinned to the old CA, so all of them must be re-provisioned with the new CA certificate. Treat it
as an owner-confirmed change with a coordinated client cutover — do not rotate the CA to fix a single
leaf. If the CA key is **lost**, that rotation is forced, because no further leaf can be issued.

## Related

- [`../adr/0009-vcap-postgres-public-ports.md`](../adr/0009-vcap-postgres-public-ports.md) — the decision, its status, and the alternatives rejected
- [`../secrets.md`](../secrets.md) — where the CA key and the leaf live
- [`../ports.md`](../ports.md) — the port inventory, with "true today" and "aimed at" kept separate
