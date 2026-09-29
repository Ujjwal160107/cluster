# DNS records are intentionally NOT declared here yet. The review §17 S2 validation gate requires
# `terraform plan` to show 0 changes to existing DNS records — that's only achievable by running
# `cf-terraforming generate --resource-type cloudflare_dns_record --zone <zone-id>` against the
# real, live zone and reconciling its output into a new dns.tf, one record at a time, discarding
# any record whose generated plan isn't zero-diff (documented below as "click-ops, known" per the
# review). Do NOT hand-write DNS records here — that's exactly the kind of fabricated resource this
# repo's tooling must never produce. `codechefvit.com` stays out of scope entirely.

variable "cloudflare_account_id" {
  description = "Cloudflare account ID (same account as DNS + R2)."
  type        = string
  default     = "92454a06150c83347f179e1b10f6ab35" # verified via GET /accounts, 2026-09-28
}

data "cloudflare_zone" "upayan_dev" {
  name = var.cloudflare_zone_name
}

# Zone settings — verified live via the API on 2026-09-28 (GET /zones/<id>/settings/<setting>),
# NOT the values docs/certificates.md assumed. This resource imports the CURRENT state for a
# true zero-diff plan; changing any of these is a separate, deliberate decision, not bundled here.
#
# ⚠️ REAL FINDING, resolved 2026-09-28: min_tls_version was actually "1.0" live, not "1.2" as
# docs/plans/2026-09-27-architecture-review.md §10 and docs/certificates.md assumed — the docs were
# wrong, not this config. Reviewed as a separate, confirmed change (NET-005), because raising it can
# break very old TLS 1.0/1.1 clients, and **set to "1.2" here** on the owner's explicit authorisation.
#
# STATUS: the file says 1.2 but the live zone still reports 1.0, because applying it needs a
# Cloudflare API token with **Zone Settings: Edit** and this workstation only holds an
# SSL-and-Certificates token. So `terraform plan` on this resource is expected to show exactly one
# in-place update until someone applies it. Do not "fix" that by reverting the value — the value is
# the decision; the apply is the missing step. Rollback if 1.2 breaks a client: set it back to "1.0"
# and re-apply.
resource "cloudflare_zone_settings_override" "upayan_dev" {
  zone_id = data.cloudflare_zone.upayan_dev.id
  settings {
    ssl                      = "strict"
    always_use_https         = "on"
    min_tls_version          = "1.2" # NET-005, owner-authorised 2026-09-28 (was 1.0)
    automatic_https_rewrites = "on"
  }
}

# R2 buckets — created, and both are in state (verified 2026-09-29). Object Lock (bucket-lock rule)
# for vps-backups is applied per the review §12.7 once S4 validates that restic can tolerate it; not set
# here to avoid blocking bucket creation on an unvalidated assumption, and DR-003's daily workstation
# mirror covers the same "survives losing both providers" case meanwhile.
#
# **What this provider cannot express (measured 2026-09-29, TF-001).** `terraform providers schema`
# against the pinned `cloudflare ~> 4.0` lists exactly one R2 resource — `cloudflare_r2_bucket`, with
# attributes `account_id`, `location`, `name`, `id`. There is **no versioning and no bucket-lock rule**
# in it. So:
# **R2 does not implement S3 bucket versioning.** Verified 2026-09-29 against Cloudflare's own S3 API
# compatibility page (developers.cloudflare.com/r2/api/s3/api/), which lists both `GetBucketVersioning` and
# `PutBucketVersioning` under *Unimplemented bucket-level operations*, and against the account API, whose
# bucket resource returns only `creation_date`, `jurisdiction`, `location`, `name` and `storage_class` —
# there is no versioning field to set. An earlier note here asked for versioning to be enabled in the
# dashboard, saying it "cannot be Terraformed at this provider version"; the premise was wrong twice over.
# The protection that *does* exist on R2 is already configured: `use_lockfile = true` in the backend block,
# which stops two applies writing the state at once. **Bucket Lock is deliberately not used** — it is WORM,
# and Terraform has to overwrite the state object on every operation. The archive safeguard is the offline
# copy of the pre-R2 state under ~/.local/share/vps-tfstate-backup/ on the owner's workstation.
resource "cloudflare_r2_bucket" "vps_backups" {
  account_id = var.cloudflare_account_id
  name       = "vps-backups"
  location   = "WEUR" # Western Europe, closest to Hetzner fsn1

  # P3-05: the backup leg is the only copy of the cluster that is not on the cluster. Losing this
  # bucket is losing every offsite restic snapshot, and R2 keeps no versioning (see the header), so
  # there is nothing to restore from afterwards. `prevent_destroy` makes it a two-step, deliberate
  # act rather than a side effect of a refactor.
  lifecycle {
    prevent_destroy = true
  }
}

resource "cloudflare_r2_bucket" "vps_tfstate" {
  account_id = var.cloudflare_account_id
  name       = "vps-tfstate"
  location   = "WEUR"

  # P3-05: Terraform state for the whole provider layer. Deleting the bucket destroys the only
  # record of what exists; the offline snapshots under ~/.local/share/vps-tfstate-backup/ become the
  # recovery path, which is a worse one.
  lifecycle {
    prevent_destroy = true
  }
}

# Cloudflare Access (ArgoCD/Grafana) — created in S6, not here. See docs/plans/2026-09-27-architecture-review.md
# §17 S2/S6 and docs/networking.md. `var.access_allowed_emails` is already defined for that stage.
