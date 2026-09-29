# TF-004: a replacement-server path, for the day the existing one cannot be recovered to.
#
# This file creates **nothing** by default, and it never touches `hcloud_server.vps`, which keeps its
# `prevent_destroy`, its `delete_protection`, its `rebuild_protection` and its `ignore_changes`. The pattern
# those protections exist for — a fresh node joining the same tailnet, with the data volume reattaching to it
# and DNS moved deliberately — is DR-006's fresh-host validation, which is what uses this.
#
# Nothing here is a substitute for restoring the existing node: the state of the world (etcd snapshot, R2
# restic repository, the static PVs' data volume) is what makes a rebuild survivable, and this only supplies
# the machine. See docs/disaster-recovery.md.

variable "enable_rebuild_server" {
  description = "Create the replacement server (TF-004). Off by default: a `terraform plan` with it off must show no changes, and turning it on costs money."
  type        = bool
  default     = false
}

variable "rebuild_server_tailscale_auth_key" {
  description = <<-EOT
    Tailscale auth key for the replacement node, supplied at apply time from the environment
    (TF_VAR_rebuild_server_tailscale_auth_key=...), never from a committed file. It is `sensitive`, so it is
    not printed in plan or apply output. Generate it in the Tailscale admin console as a one-off, pre-authorised
    key, and revoke it in the same console once the node is up — a key that survives its use is a credential
    nobody is watching.
  EOT
  type        = string
  sensitive   = true
  default     = ""
}

locals {
  # The node name the tailnet will show, and the hostname the machine gives itself. Distinct from `vps`
  # deliberately: two machines answering to one name is how a rebuild becomes an outage.
  rebuild_server_name = "vps-rebuild"

  rebuild_server_cloud_init = <<-EOT
    #cloud-config
    # Deliberately minimal. This installs Tailscale and joins the tailnet — nothing else. The cluster's own
    # configuration is Ansible's job (`ansible/site.yml`), which is idempotent and runs against whatever host
    # it is pointed at; duplicating any of it here would create a second source of truth for host state.
    #
    # The install script is Tailscale's documented method. `--ssh` is included because the repository's target
    # is Tailscale as the only admin path (firewall.tf, S6), and it is the one setting whose absence would
    # leave the new node unreachable once the public rules come off.
    package_update: true
    runcmd:
      - [ sh, -c, "curl -fsSL https://tailscale.com/install.sh | sh" ]
      - [ sh, -c, "tailscale up --authkey=${var.rebuild_server_tailscale_auth_key} --ssh --hostname=${local.rebuild_server_name} --accept-routes" ]
  EOT
}

resource "hcloud_server" "rebuild" {
  count = var.enable_rebuild_server ? 1 : 0

  name        = local.rebuild_server_name
  server_type = "cx33" # same shape as the existing node, so the Ansible run and the workloads fit
  image       = "ubuntu-24.04"
  location    = "fsn1"

  backups = false # owner decision 2026-09-28, unchanged: restic/R2 is the backup path, see docs/backups.md

  # Disposable by design, unlike `hcloud_server.vps`: this one exists to be destroyed after the drill, and a
  # protect-the-drill-server default is how a rebuild path quietly stops being exercisable.
  delete_protection  = false
  rebuild_protection = false

  ssh_keys = [
    hcloud_ssh_key.vps_root.id,
    hcloud_ssh_key.upayan_sonder.id,
  ]

  # TF-004 fix, landed with this file's move into `cluster` (P3-04): `firewall_ids` is NOT set here.
  # `hcloud_firewall_attachment.vps` owns the firewall membership for both machines
  # (`server_ids = concat([hcloud_server.vps.id], hcloud_server.rebuild[*].id)`), so setting it here
  # as well would be two owners for one attribute — and the one that loses is whichever refreshes
  # last. The symptom is quiet: a rebuild node that is up but has no rules, or the existing node
  # losing its attachment because a plan that only created the rebuild server rewrote the set.
  # Attached rather than a second firewall: a rebuild that needed different rules would be a
  # different node.

  user_data = local.rebuild_server_cloud_init

  lifecycle {
    # Without this, enabling the flag with an empty key produces a node whose cloud-init runs
    # `tailscale up --authkey=` and joins nothing — a machine that costs money, has no admin path, and
    # is only discoverable after the fact. The failure is cheap to prevent and expensive to diagnose,
    # which is the test for whether a check is worth writing.
    #
    # It is a **resource** precondition, not a `variable` `validation`, and that is not style: a
    # variable validation may only refer to its own variable, so expressing "these two variables must
    # agree" there is rejected outright by Terraform 1.7 (the version CI pins) with
    # *"The condition for variable … can only refer to the variable itself"*. Terraform 1.15 accepts
    # it — which is how this shipped broken and green locally: run #36578697979 failed at
    # `terraform init` in `cluster` while the same configuration validated on a 1.15.9 workstation.
    # A precondition is evaluated whenever the resource is planned, i.e. exactly when the flag is on.
    precondition {
      condition     = length(var.rebuild_server_tailscale_auth_key) > 0
      error_message = "enable_rebuild_server = true requires rebuild_server_tailscale_auth_key (TF_VAR_rebuild_server_tailscale_auth_key)."
    }

    # `user_data` embeds the Tailscale auth key. Without this, a later plan that changed any *other*
    # attribute of this resource would want to rewrite `user_data` — and, being sensitive, the diff
    # is unreadable, so the change would be approved blind. Ignoring it also means the key is never
    # re-read from state and re-applied to a machine that already joined the tailnet.
    #
    # Consequence, and it is the reason for the warning below: the auth key is written into state
    # (and into a saved plan) while the variable is set. Never `-out` a plan while a real key is
    # supplied, and destroy the server's resources once the drill is finished.
    ignore_changes = [user_data]
  }
}

# The drill node is disposable, so it is not protected — but the *class* of mistake this file could
# make is worth stating. Never `terraform plan -out=<file>` while
# `rebuild_server_tailscale_auth_key` holds a real key: the plan file contains the resolved
# `user_data`, i.e. the key, in plaintext. P3-07's state-only apply uses a plan file with the
# variable unset, which is safe.

output "rebuild_server_ipv4" {
  description = "The replacement node's public IPv4, once enabled (TF-004). Empty when the variable is off."
  value       = var.enable_rebuild_server ? hcloud_server.rebuild[0].ipv4_address : ""
}

output "rebuild_server_hint" {
  description = "What to do with the node this creates, so the next step is not a search."
  value       = var.enable_rebuild_server ? "Point ansible at it (`-e ansible_host=<ip>`) once it has joined the tailnet, then follow docs/runbooks/recover-k3s.md; destroy it with `-var enable_rebuild_server=false` after the drill." : "disabled"
}
