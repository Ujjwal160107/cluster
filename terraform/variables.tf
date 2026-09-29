variable "hetzner_server_id" {
  description = "Existing Hetzner server ID to import (never create a second one)."
  type        = number
  default     = 122385524 # verified: docs/inventory.md, review §2.1
}

# Removed 2026-09-28 (CLEAN-002): `hetzner_primary_ipv{4,6}_id` and `vcap_{dev,staging}_volume_id`.
# They were declared and never referenced — the real ids live inline in `imports.tf`, where Terraform
# needs them for the import blocks, so these were duplicates that invited someone to set the wrong one
# and wonder why nothing changed. `terraform validate` passes without them.

variable "access_allowed_emails" {
  description = "Cloudflare Access allow-list for the ArgoCD/Grafana admin UIs (N3; not yet applied). Empty by default — the value belongs in a git-ignored *.auto.tfvars (TF-003)."
  type        = list(string)
  # Deliberately EMPTY, and deliberately still declared (SEC-006 + TF-003 + CI-007, 2026-09-28):
  #   - the owner's address used to be the default here, which made this file one of the six
  #     publication blockers `docs/plans/redaction-checklist.md` tracks — a personal email in a file
  #     the public repo would carry. The value belongs in a git-ignored `*.auto.tfvars` (TF-003);
  #   - the *declaration* stays because N3 (Cloudflare Access in front of ArgoCD and Grafana) needs
  #     it, and removing the seam would just move the work to that task without removing the PII.
  #     Until 2026-09-29 it was also reported by tflint as unused, which is why
  #     `terraform_unused_declarations` is disabled in `.tflint.hcl`; `access.tf` now consumes it, so
  #     that disable is no longer load-bearing for this variable (left in place, since tflint cannot be
  #     run from the workstation — see the 2026-09-29 changelog entries on linters that only exist in CI).
  default = []
}

variable "enable_cloudflare_access" {
  description = "Create the Cloudflare Access applications and allow-policies in front of the ArgoCD/Grafana UIs (N3). Off by default: with it off, `terraform plan` shows no changes."
  type        = bool
  default     = false

  validation {
    # Why a guard rather than a comment asking nicely: enabling Access with an empty allow-list denies
    # *everyone*, including the owner, and the way out is not obvious from the ArgoCD UI you can no
    # longer reach. This is the same class of "the plan cannot express a broken state" check as the
    # rebuild-server auth key (P3-04), and it fires at plan time, before anything is created.
    condition     = !var.enable_cloudflare_access || length(var.access_allowed_emails) > 0
    error_message = "enable_cloudflare_access = true requires access_allowed_emails to name at least one identity — an Access policy with an empty allow-list would lock every user, including you, out of the ArgoCD and Grafana UIs."
  }
}

variable "emergency_ssh_cidr" {
  description = "Temporary /32 CIDR to allow tcp/22 through the Hetzner firewall for break-glass recovery when Tailscale is unreachable (S6 target state). Empty = no rule. Remove after use — this is a manual, confirmed, temporary override, never left set."
  type        = string
  default     = ""
}

variable "cloudflare_zone_name" {
  description = "The zone this repo's Terraform manages. codechefvit.com is explicitly out of scope."
  type        = string
  default     = "upayan.dev"
}
