# SSH keys — imported (see imports.tf). Public keys only (not sensitive), fetched directly from
# the Hetzner API on 2026-09-28 via `GET /v1/ssh_keys`.
resource "hcloud_ssh_key" "vps_root" {
  name       = "vps-root"
  public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGVvqdigrXo93RSq2vY3oZ3v+Hf8MoGUTsgrcJhGSJRJ"

  lifecycle {
    prevent_destroy = true
  }
}

resource "hcloud_ssh_key" "upayan_sonder" {
  name       = "upayan@sonder-hetzner-2026"
  public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE1kSEaaTPlyvOluQUWvm4tD/sAOnkCiGaDcuWA33gvi"

  lifecycle {
    prevent_destroy = true
  }
}
