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
  description = "Cloudflare Access allow-list for the ArgoCD/Grafana admin UIs (NET-004, not yet applied)."
  type        = list(string)
  # Deliberately EMPTY, and deliberately still declared (SEC-006 + TF-003 + CI-007, 2026-09-28):
  #   - the owner's address used to be the default here, which made this file one of the six
  #     publication blockers `docs/plans/redaction-checklist.md` tracks — a personal email in a file
  #     the public repo would carry. The value belongs in a git-ignored `*.auto.tfvars` (TF-003);
  #   - the *declaration* stays because NET-004 (Cloudflare Access in front of ArgoCD and Grafana)
  #     needs it, and removing the seam would just move the work to that task without removing the
  #     PII. `tflint` therefore reports it as an unused declaration, which is why that single rule is
  #     disabled in `.tflint.hcl` with this same reason written next to it.
  default = []
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
