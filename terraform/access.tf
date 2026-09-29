# N3 (P7): Cloudflare Access in front of the ArgoCD and Grafana admin UIs.
#
# Why it exists: `argocd.upayan.dev` and `grafana.upayan.dev` are reachable by anyone who knows the
# hostname. ArgoCD is the cluster's control plane and Grafana holds the VCAP log dashboards, so until
# N3 lands, the *only* thing in front of them is a login form. Access puts an identity check at
# Cloudflare's edge, before the request ever reaches Traefik.
#
# **Nothing here is applied.** Everything is gated on `enable_cloudflare_access` (default **false**),
# so `terraform plan` on the current tree shows no changes at all — verified, not assumed. Two reasons
# for the gate rather than creating the resources unconditionally:
#
#   1. **An Access policy with an empty allow-list is an outage.** It would deny everyone, including
#      the owner, for ArgoCD — and the recovery path (port-forward) is a workstation trick, not
#      something to discover at the moment the control plane is dark. The `lifecycle.precondition` on
#      `cloudflare_zero_trust_access_application.admin_ui` makes that state unrepresentable: flipping
#      the flag without supplying identities fails the plan before anything is created.
#   2. The plan's own ordering puts N3 after N2 (a proven tailnet path), because the documented
#      fallback for the ArgoCD CLI is `kubectl port-forward` over the tailnet rather than through the
#      browser.
#
# To turn it on, an operator supplies the identities out-of-band (never in git — a personal address in
# a published file is exactly what `docs/plans/redaction-checklist.md` §1 exists to stop):
#
#   cat > terraform/access.auto.tfvars          # git-ignored; TF-003
#   enable_cloudflare_access = true
#   access_allowed_emails    = ["<owner address>", "<second admin>"]
#
#   ../scripts/tf.sh plan     # expect: 2 applications + 2 policies to add, nothing else
#   ../scripts/tf.sh apply
#
# **And N3 is not finished by applying this.** The plan's step also removes `web` from the Ingress
# entrypoints (`k8s/platform/argocd/values.yaml`, `k8s/monitoring/grafana-ingress.yaml`) so those UIs
# are served over TLS only, and that is a separate, deliberate change to make *after* Access is
# verified working — doing it first would remove the plain-HTTP path while nothing guarded the HTTPS
# one. Verify with:
#
#   curl -sI https://argocd.upayan.dev | grep -ci cloudflareaccess.com      # >= 1
#   curl -sI https://grafana.upayan.dev | grep -ci cloudflareaccess.com     # >= 1
#
# Only then is OD-12's precondition (N3 + N4) satisfiable for publication (P8-04).

# **Resource names, and a deliberate deviation.** The plan names `cloudflare_access_application` and
# `cloudflare_access_policy`. The pinned provider (`cloudflare ~> 4.0`, resolved to 4.52.9) marks both
# **deprecated, to be removed in the next major version**, and directs callers to
# `cloudflare_zero_trust_access_application` / `cloudflare_zero_trust_access_policy`. This file uses the
# non-deprecated pair, so `terraform validate` is clean instead of emitting two deprecation warnings on
# every run. Same resources, same provider, newer names — the plan's *intent* is unchanged.
#
# **Measured 2026-09-29, all three states, before committing:**
#   | `enable_cloudflare_access` | `access_allowed_emails` | `terraform plan` |
#   |---|---|---|
#   | false (default) | `[]` | **No changes.** Your infrastructure matches the configuration. |
#   | true | `[]` | **refused** — `Resource precondition failed: enable_cloudflare_access = true requires access_allowed_emails…` |
#   | true | `["<one address>"]` | **`Plan: 4 to add, 0 to change, 0 to destroy`** (2 applications + 2 policies) |
# So the gate is real in both directions: it cannot lock anyone out by being applied empty, and it does
# do exactly what it claims when armed.

locals {
  # `{}` when the feature is off, which is what makes the resources below disappear from the plan
  # rather than being created.
  access_admin_uis = var.enable_cloudflare_access ? {
    argocd  = "argocd.upayan.dev"
    grafana = "grafana.upayan.dev"
  } : {}
}

resource "cloudflare_zero_trust_access_application" "admin_ui" {
  for_each = local.access_admin_uis

  # The narrower, Access-only token (`TF_VAR_cloudflare_access_api_token`). The default provider's
  # token cannot write Access at all — measured: even a read is refused with `10000 Authentication
  # error` — and this token cannot touch R2, DNS or zone settings. Each provider is used where it has
  # authority, and neither can act outside its scope (`providers.tf`).
  provider = cloudflare.access

  zone_id = data.cloudflare_zone.upayan_dev.id
  name    = each.key
  domain  = each.value

  # `self_hosted` is the type for an application behind a proxy that Cloudflare does not own; the
  # ArgoCD and Grafana UIs are ours, fronted by Traefik. It is also the only type whose validation
  # error the scope probe saw (`12130 … app type is missing or invalid`), which is how we know the
  # stored token can write here at all.
  type = "self_hosted"

  # Long enough not to re-authenticate during a working session, short enough that a lost laptop does
  # not stay logged in. Grafana is where the VCAP log dashboards live, so it is not a trivial session.
  session_duration = "24h"

  lifecycle {
    # The guard against an empty allow-list, and it has to live *here* rather than in a `validation` on
    # `enable_cloudflare_access`: a variable validation may only refer to its own variable, so
    # "these two variables must agree" is rejected outright by Terraform 1.7 — the version CI pins —
    # at `terraform init`. A precondition can reference both, and it is evaluated exactly when this
    # resource is planned, i.e. only when the feature is on. When the feature is off, `for_each` is
    # empty, no instance is planned, and nothing is evaluated: the default path stays inert.
    precondition {
      condition     = length(var.access_allowed_emails) > 0
      error_message = "enable_cloudflare_access = true requires access_allowed_emails to name at least one identity — an Access policy with an empty allow-list would lock every user, including you, out of the ArgoCD and Grafana UIs."
    }

    # N3's second guard: the Access provider alias needs its own token, and an empty one produces
    # "10000 Authentication error" from Cloudflare at apply time — an error that names the API, not the
    # missing configuration. Say it here instead, where the fix is obvious. (Measured 2026-09-29: the
    # default provider's token fails this call even though it is valid and active, because it carries
    # no Access permission.)
    precondition {
      condition     = length(var.cloudflare_access_api_token) > 0
      error_message = "enable_cloudflare_access = true requires cloudflare_access_api_token to be set (TF_VAR_cloudflare_access_api_token in the SOPS secrets file). The default provider's token has no Access permission — Cloudflare answers 'Authentication error (10000)' — so the Access resources are wired to the `cloudflare.access` alias and need a token that can write them."
    }
  }
}

resource "cloudflare_zero_trust_access_policy" "admin_ui_allow" {
  for_each = local.access_admin_uis

  # Same Access-only token as the application it attaches to; a policy written with the broad token
  # would fail the same way (the policy API is part of the Access permission group).
  provider = cloudflare.access

  zone_id        = data.cloudflare_zone.upayan_dev.id
  application_id = cloudflare_zero_trust_access_application.admin_ui[each.key].id

  # First (and only) policy, so there is no ordering subtlety: allow the named identities, deny
  # everything else, which is Access' default when no policy matches.
  precedence = 1
  name       = "allow-${each.key}"
  decision   = "allow"

  include {
    # One block, many addresses — the shape the provider expects. `var.access_allowed_emails` is
    # validated non-empty when the feature is enabled, so this can never be an empty allow-list.
    email = var.access_allowed_emails
  }
}
