# tflint config — CI-007 (partial), adopted 2026-09-28.
#
# Small Terraform (10 files), so the ruleset is left at its bundled defaults and only one rule is
# turned off — with the specific reason, because a blanket "disable the noisy rule" habit is how a
# linter stops finding anything:
rule "terraform_unused_declarations" {
  enabled = false
}
# `access_allowed_emails` is declared and not yet used ON PURPOSE: it configures NET-004's Cloudflare
# Access applications, which are not written yet, and it is kept as a declared seam so that NET-004
# only has to supply a value (from a git-ignored tfvars, per TF-003). Its default is empty rather than
# the owner's address, which is what made `terraform/variables.tf` one of SEC-006's publication
# blockers. Every other bundled rule — including the ones that found real problems here already, such
# as the four variables removed by CLEAN-002 — stays on.
