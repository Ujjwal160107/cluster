# Machine inventory

Factual reference sheet — "what is this machine, exactly." Source: §1 and §2.1 of the architecture
review (kept private, not published). Verified 2026-09-27 via Hetzner API GETs and `ssh`/`kubectl`
read commands.

## Hetzner project

| Resource | ID / value | Notes |
|---|---|---|
| Server `vps` | 122385524, cx33, fsn1, created 2026-02-28 | backups off, delete/rebuild protection off, no firewall attached (S0 owner action pending — see `../changelog/2026-09.md`) |
| Primary IPv4 | 138.201.157.147 | `auto_delete=true` (deleting the server loses the IP) — S0 owner action pending |
| Primary IPv6 | 2a01:4f8:c012:957::/64 | `auto_delete=true` — S0 owner action pending |
| Volume 106574316 | `pvc-807fffe3-057e-4b2c-a5f6-6aa3b7e38bfa`, 10 GB | vcap-dev data (hcloud CSI); PV patched to `Retain` in S0; protection off |
| Volume 106574315 | `pvc-55404a44-5cab-42ee-84d8-ab8a6490467e`, 10 GB | vcap-staging data (hcloud CSI); PV patched to `Retain` in S0; protection off |
| Volume 106353532 | **does not exist** | still referenced by PV `pvc-6d634268-5fbb-4830-8116-5472acb00922` (smart-home-system-api PVC, deploy scaled 0/0). Deliberate loss, owner-confirmed; PV intentionally left `Delete` in S0 |
| Firewalls / networks / LBs / floating IPs / snapshots / backups | none | target: Terraform-managed firewall + R2 buckets (S2) |
| SSH keys (Hetzner project) | `vps-root`, and the owner's personal key (its name is an address — held privately) | |

## k3s

| Field | Value |
|---|---|
| Version | `v1.34.4+k3s1` |
| Topology | single server, embedded etcd (`cluster-init` leftover from a since-removed 2-node era — the second node was removed, see the stale-reference cleanup below)
| Flags | `--tls-san vps.upayan.dev`, `--node-ip=138.201.157.147`, `--node-external-ip=100.96.250.81`, `--flannel-iface=tailscale0` |
| Node name | `vps` |
| Bootstrap | `k8s/bootstrap/root-app.yaml`, applied once by hand — see `k8s/bootstrap/README.md` |

## Host

| Field | Value |
|---|---|
| OS | Ubuntu 24.04.5, kernel 6.8.0-142 |
| Public IPv4 | 138.201.157.147 |
| Public IPv6 | 2a01:4f8:c012:957::/64 |
| Tailscale IP | 100.96.250.81 |
| Disk | 75 GB root (ext4), ~73% used as of 2026-09-27 |
| Patching | `unattended-upgrades` on (OS packages only, no cadence beyond that — see `upgrade-policy.md`) |

## Cloudflare

| Field | Value |
|---|---|
| Zone | `upayan.dev` (every record orange-clouded/proxied) |
| SSL mode | Full (strict), already set, owner-confirmed |
| Out of scope | `codechefvit.com` zone (someone else's) |
| Target-managed by | Terraform, only if the import plan is zero-diff (S2) |

## Contacts

Roles are here because they are what the cluster's access model is built on; **names and addresses are held
privately** (the owner's password manager, mirrored in the repository's private notes) so that this document
can be published without carrying personal data. Delete the private copy once it is in the password manager.

| Role | Access |
|---|---|
| Owner / admin | Tailnet (SSH, kubectl), Cloudflare Access allow-list, only tailnet identity in the target design |
| vcap dev | Public Postgres DB credentials only (target 15432/15433 with TLS + per-person roles; **not open yet**, and 5432/5433 never reopen) — **no tailnet access** |
| vcap dev | Same as above — DB credentials only, no tailnet |

## Related

- [`architecture.md`](architecture.md) — how these pieces fit together, current and target
- [`storage.md`](storage.md) — what's on the two CSI volumes and the root disk
- [`ports.md`](ports.md) — what's reachable on this machine and from where
