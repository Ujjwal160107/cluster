output "server_id" {
  value = hcloud_server.vps.id
}

output "server_ipv4" {
  value = hcloud_primary_ip.ipv4.ip_address
}

output "server_ipv6" {
  value = hcloud_primary_ip.ipv6.ip_address
}

output "firewall_id" {
  value = hcloud_firewall.vps.id
}

output "r2_backups_bucket" {
  value = cloudflare_r2_bucket.vps_backups.name
}

output "r2_tfstate_bucket" {
  value = cloudflare_r2_bucket.vps_tfstate.name
}

# P3-05 (OD-5): a sentinel, not a fact anyone needs — it exists so "which configuration owns this
# state?" has a machine-readable answer in the state itself. Both repositories used to hold this
# same configuration against this same key (`s3://vps-tfstate/vps/terraform.tfstate`), so a plan run
# from the wrong checkout was indistinguishable from a correct one until it applied. After P3-06
# `vps/terraform` holds no configuration at all; this output is what makes that verifiable from the
# state rather than from a directory listing.
output "state_owner" {
  value = "github.com/upayanmazumder/cluster//terraform"
}
