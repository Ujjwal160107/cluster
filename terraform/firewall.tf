# S2: created PERMISSIVE — mirrors today's de-facto-open state so attaching it changes nothing
# yet. The final locked-down ruleset is a separate, later change to this file — do not jump ahead
# to it here.
#
# Postgres ports: the 5432/5433 rules below are a leftover. **5432/5433 are closed and must not be
# reopened** — nothing serves them (the unmanaged NodePort duplicates were deleted and the tenant
# chart's same-namespace NetworkPolicy blocks the Traefik path), and the owner decision (OD-1) makes
# **15432 (dev) / 15433 (staging)** the target public path, which is **NOT OPEN YET**: no rule for
# those ports exists here yet, and the hardening they depend on (TLS, per-person non-superuser roles,
# a network-superuser-locking pg_hba, auth-failure alerting) does not exist either. Leave 5432/5433
# closed; add 15432/15433 only together with that hardening.

# N4 (P7): restrict 80/443 to Cloudflare's edge. Fetched, never hand-copied — a static list rots
# silently, and a wrong range list here is a total ingress outage (Cloudflare can reach nothing, every
# host 5xx). The provider data source was confirmed present in the pinned version
# (`terraform providers schema`: `cloudflare_ip_ranges` exposes `ipv4_cidr_blocks`, `ipv6_cidr_blocks`,
# `china_ipv4_cidr_blocks`, `china_ipv6_cidr_blocks`).
#
# The **China-network ranges are included deliberately.** Cloudflare's China network reaches origins
# from those, so a rule built from the main lists alone silently drops that traffic — and a silently
# dropped visitor is indistinguishable from a broken site. Including them cannot break anyone;
# excluding them can. (The previous version of this comment asked for exactly this decision to be made
# before the apply rather than discovered after it.)
data "cloudflare_ip_ranges" "cf" {}

locals {
  # Gated, so that the currently applied firewall is **provably unchanged** until an operator opts in:
  # with the flag off this is byte-identical to the `["0.0.0.0/0", "::/0"]` it replaces, and
  # `terraform plan` reports no changes (measured — see the changelog entry).
  #
  # Only 80 and 443 are affected. 22 and 6443 are NOT narrowed here: that is N5, and it depends on a
  # working tailnet (N2) rather than on Cloudflare.
  http_https_source_ips = var.cloudflare_only_ingress ? concat(
    data.cloudflare_ip_ranges.cf.ipv4_cidr_blocks,
    data.cloudflare_ip_ranges.cf.ipv6_cidr_blocks,
    data.cloudflare_ip_ranges.cf.china_ipv4_cidr_blocks,
    data.cloudflare_ip_ranges.cf.china_ipv6_cidr_blocks,
  ) : ["0.0.0.0/0", "::/0"]
}

resource "hcloud_firewall" "vps" {
  name = "vps"

  # Inbound
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "80"
    source_ips = local.http_https_source_ips
  }
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "443"
    source_ips = local.http_https_source_ips
  }
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "6443"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "5432"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "5433"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
  rule {
    direction  = "in"
    protocol   = "udp"
    port       = "41641"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
  rule {
    direction  = "in"
    protocol   = "icmp"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  # Break-glass only: set via `-var emergency_ssh_cidr=<ip>/32` and apply, then re-apply with it
  # unset immediately after use. Empty by default = no extra rule.
  dynamic "rule" {
    for_each = var.emergency_ssh_cidr != "" ? [1] : []
    content {
      direction  = "in"
      protocol   = "tcp"
      port       = "22"
      source_ips = [var.emergency_ssh_cidr]
    }
  }
}

resource "hcloud_firewall_attachment" "vps" {
  firewall_id = hcloud_firewall.vps.id
  # TF-004 (P3-04): the rebuild node joins this set rather than carrying its own `firewall_ids`.
  # One owner for firewall membership, so a plan that creates the rebuild server cannot also be a
  # plan that detaches the existing one. `[*]` on a `count = 0` resource is the empty list, so with
  # the rebuild variable off this is byte-identical to the previous behaviour.
  server_ids = concat([hcloud_server.vps.id], hcloud_server.rebuild[*].id)
}

# S6 target (not yet applied — tracked here as the documented next step, do not act on this
# comment without the S6 stage's own confirmation gate):
#   - keep the 5432/5433 from-anywhere rules — that part is permanent, owner-confirmed
#   - restrict 80/443 source_ips to Cloudflare's published ranges
#   - remove the plain tcp/22 and tcp/6443 rules entirely (Tailscale is the only admin path)
#
# Before you touch this, two things (both verified 2026-09-28):
#
#  1. PREREQUISITE: Tailscale must actually be working on every admin machine first. Removing the
#     public 22/6443 rules is only safe if the tailnet path exists, and today it does not for at
#     least one admin workstation (`tailscale` is not even installed there, and the kubeconfig
#     points at `https://138.201.157.147:6443`, i.e. the public address). Locking 6443 first would
#     cut `kubectl` for whoever is working from such a machine — ArgoCD itself is unaffected
#     in-cluster. Keep SSH reachable until the tailnet path is proven from every admin machine.
#     Also note the server is currently reachable on 6443 from the public internet (confirmed by
#     probing the port from a workstation), which is exactly what this change is for.
#
#  2. CLOUDFLARE RANGES: fetch them, do not hand-maintain a static list. The public, no-auth
#     endpoint works and is what the S6 executor should use:
#       curl -s https://api.cloudflare.com/client/v4/ips | jq -r '.result.ipv4_cidrs[], .result.ipv6_cidrs[]'
#     (15 IPv4 + 7 IPv6 ranges as of 2026-09-28). The comment that used to sit here suggested a
#     provider data source. **Confirmed 2026-09-28 against the pinned provider** (`cloudflare ~> 4.0`,
#     `terraform providers schema`): `data.cloudflare_ip_ranges` exists and is not deprecated, exposing
#     `ipv4_cidr_blocks` and `ipv6_cidr_blocks` — so the data source is the better route and the API
#     fetch above is the fallback, not the other way round.
#
#     **One decision that data source makes explicit and a hand-copied list hides:** it also exposes
#     `china_ipv4_cidr_blocks` / `china_ipv6_cidr_blocks`. Cloudflare's China network reaches the origin
#     from those ranges, so a rule built from the main lists alone silently drops that traffic. Either
#     include them deliberately or record that China-network visitors are out of scope — do not discover
#     it after the apply.
#
# Reminder of why this is deferred rather than done: the failure mode is a total ingress outage
# (Cloudflare can reach nothing, every host 5xx) plus loss of kubectl, and it is reversible only
# through the Hetzner Cloud console (which the owner holds) or from an already-open session.
