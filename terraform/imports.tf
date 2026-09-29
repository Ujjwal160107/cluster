# Import blocks — Terraform 1.5+ declarative import.
#
# All five imports are ACTIVE (server, both primary IPs, both SSH keys) — the ids were verified
# against the live Hetzner API on 2026-09-28 and are inline below. This comment used to say only the
# server import was active and that the rest needed API-only values; that stopped being true when the
# ids were filled in (CLEAN-002 corrected it).
#
# Still do not fabricate an id: what remains unimported is deliberate, not missing — the two vcap CSI
# volumes are not Terraform-managed, and DNS records are not declared in `cloudflare.tf` at all until
# `cf-terraforming` produces a zero-diff set (see that file's header and TF-002).

import {
  to = hcloud_server.vps
  id = var.hetzner_server_id # 122385524, verified
}

# Primary IPs — IDs verified via the Hetzner API on 2026-09-28.
import {
  to = hcloud_primary_ip.ipv4
  id = "120161043"
}
import {
  to = hcloud_primary_ip.ipv6
  id = "120161044"
}

# SSH keys — public key bodies verified via the Hetzner API on 2026-09-28 (see ssh-keys.tf).
import {
  to = hcloud_ssh_key.vps_root
  id = "112397620"
}
import {
  to = hcloud_ssh_key.upayan_sonder
  id = "116357397"
}

# Do NOT import the two vcap CSI volumes (106574315, 106574316) — retired in S8, not
# Terraform-managed ever (see variables.tf comments).
