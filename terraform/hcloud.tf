# Server — imported (see imports.tf), never created by this config.
#
# `image` and `ssh_keys` are marked ignore_changes because Terraform cannot mutate them on an
# existing server without a rebuild, and this repo must never rebuild the server. name/server_type/
# image/location verified via the Hetzner API on 2026-09-28 (exact match, no drift).
resource "hcloud_server" "vps" {
  name               = "vps"
  server_type        = "cx33"
  image              = "ubuntu-24.04"
  location           = "fsn1"
  backups            = false # owner decision 2026-09-28: costs 20% of server plan, over budget — restic/R2 is the real backup path, see docs/backups.md
  delete_protection  = true  # applied and verified live 2026-09-28 (`terraform plan` reports no diff)
  rebuild_protection = true  # applied and verified live 2026-09-28

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [image, user_data, ssh_keys, server_type, location]
  }
}

# Primary IPs — verified names via the Hetzner API on 2026-09-28.
# `auto_delete = false` keeps the IP alive when the server goes, so DNS survives a rebuild.
# Applied and verified live 2026-09-28 (`terraform plan` reports no diff) — an earlier note here said the
# live value was still `true`; it is not.
resource "hcloud_primary_ip" "ipv4" {
  name              = "vps legacy ipv4"
  type              = "ipv4"
  assignee_id       = hcloud_server.vps.id
  assignee_type     = "server"
  auto_delete       = false
  delete_protection = true

  lifecycle {
    prevent_destroy = true
  }
}

resource "hcloud_primary_ip" "ipv6" {
  name              = "vps legacy ipv6"
  type              = "ipv6"
  assignee_id       = hcloud_server.vps.id
  assignee_type     = "server"
  auto_delete       = false
  delete_protection = true

  lifecycle {
    prevent_destroy = true
  }
}

# The two vcap CSI volumes (106574315 staging, 106574316 dev) are intentionally NOT declared here.
# They stay hcloud-CSI-managed until S8 retires them (data moves to the new `vps-data` volume) —
# see docs/storage.md. The `vps-data` volume itself is created in S8, not here.
