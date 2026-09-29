# Runbook: VCAP Postgres external access (15432 / 15433)

How the tenant's developers reach the VCAP dev and staging Postgres instances — and, plainly, that
they **cannot yet**.

> ## ⚠️ These ports are not open yet
>
> **The target is `15432` (dev) and `15433` (staging), TLS-only. Neither port is open today, and
> `5432`/`5433` are not either — they are closed, or on their way to being closed.** Nothing below is
> a description of the live cluster; it is the contract that will apply once it is.
>
> The ports open only after **both**:
> 1. **P2-08's controls exist** — TLS required, a non-superuser application role, per-person
>    non-superuser roles, the superuser confined to the pod network, and auth-failure monitoring;
> 2. **the VCAP team has approved** the chart change and the application's move off the superuser
>    (OD-16).
>
> Until then, `runbooks/recover-*` and `docs/disaster-recovery.md` are the operative documents and the
> databases are not reachable from an ordinary host. ADR [`0009`](../adr/0009-vcap-postgres-public-ports.md)
> records the decision and its current status.

## The contract (once open)

| | Dev | Staging |
|---|---|---|
| Host | the node's public address (the databases are HBA-scoped, not host-scoped) | same |
| Port | **15432** | **15433** |
| TLS | required | required |
| Verification | `sslmode=verify-ca` against the VCAP Postgres edge CA | same |
| Login | a **per-person, non-superuser** role | same |
| Superuser | pod network only — never over this path | same |

`5432` and `5433` are **not** part of the contract: they are what the ports are moving *away from*, and
they are closed (ADR 0009 is explicit that the port move is not itself a security control — it stops
default-port scanning finding the databases and makes the exposure a decision rather than an
inherited accident).

### Connecting

Clients connect by **IP address**, not hostname: the edge routes with `HostSNI("*")` and the node has
no origin-direct database hostname (Cloudflare's proxy does not carry arbitrary TCP ports). That is
why the contract is `verify-ca` and not `verify-full` — there is no name for the certificate to match.

```bash
# The CA certificate is handed to you out-of-band (see "Requesting a role"); save it, do not trust
# a copy from a chat message.
psql "host=<node public IP> port=15432 dbname=<your db> user=<your role> \
      sslmode=verify-ca sslrootcert=/path/to/vcap-postgres-edge-ca.crt"
```

- `sslmode=verify-ca` requires the server certificate to chain to the CA you hold. Do **not** use
  `sslmode=require` (it accepts any certificate, so it is not verification) and do not disable TLS.
- Your role is **not** a superuser. It can reach only the database(s) it was granted; `CREATE
  DATABASE`, `CREATE ROLE` and cross-database reads are expected to fail.

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

## Rotating the TLS leaf

The edge TLS certificate is a leaf signed by a **private CA whose key lives only in the owner's
password manager and offline medium** (never in git, never on the node). The leaf is committed
SOPS-encrypted and applied by ArgoCD as the in-cluster Secret `vcap-postgres-edge-tls`, from
`k8s/apps/vcap/edge/<env>/tls.sops.yaml`.

**Leaf renewal** (a new certificate, same CA — this is the routine rotation):

1. On the workstation, generate a key and CSR for the leaf, signed by the private CA (the CA key is
   read from the password manager only for this step; never copy it to disk or scrollback).
2. Replace the `tls.crt` / `tls.key` entries in `k8s/apps/vcap/edge/<env>/tls.sops.yaml` and
   re-encrypt with `sops`.
3. Commit and push; ArgoCD applies the Secret on the next sync (or annotate the app for a hard
   refresh).
4. Roll the edge so the connections are served the new leaf — the IngressRouteTCP/Traefik data plane
   is cluster-owned (P2-05/P2-08); a `kubectl rollout restart deploy/traefik -n kube-system` in a
   window is the documented way if the leaf is loaded at start.
5. Verify from an ordinary host:
   `openssl s_client -starttls postgres -connect <public IP>:15432 -CAfile <ca> -verify_return_error`
   must verify against the CA and carry the new leaf's validity dates.

**CA rotation** (the CA key itself is being replaced) is a different, larger operation: every client
is pinned to the old CA, so all of them must be re-provisioned with the new CA certificate. Treat it
as an owner-confirmed change with a coordinated client cutover — do not rotate the CA to fix a single
leaf. If the CA key is **lost**, that rotation is forced, because no further leaf can be issued.

## Related

- [`../adr/0009-vcap-postgres-public-ports.md`](../adr/0009-vcap-postgres-public-ports.md) — the decision, its status, and the alternatives rejected
- [`../secrets.md`](../secrets.md) — where the CA key and the leaf live
- [`../ports.md`](../ports.md) — the port inventory, with "true today" and "aimed at" kept separate
