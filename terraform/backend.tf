# Phase 1 (this file, until the `vps-tfstate` R2 bucket exists): local backend.
# Phase 2 (after the first `terraform apply` creates that bucket in cloudflare.tf): switch this
# block to the commented-out S3-compatible R2 backend below, run `terraform init -migrate-state`,
# confirm the state file appears in the bucket, then delete the local `terraform.tfstate*` files
# (they're also excluded via .gitignore — never commit state, it contains resource IDs and,
# depending on the resource, potentially sensitive attributes).
#
# terraform {
#   backend "s3" {
#     bucket                      = "vps-tfstate"
#     key                         = "vps/terraform.tfstate"
#     region                      = "auto"
#     endpoint                    = "https://<account-id>.r2.cloudflarestorage.com"
#     access_key                  = null # via AWS_ACCESS_KEY_ID env var (R2 API token)
#     secret_key                  = null # via AWS_SECRET_ACCESS_KEY env var
#     skip_credentials_validation = true
#     skip_region_validation      = true
#     skip_requesting_account_id  = true
#     use_lockfile                = true
#   }
# }
#
# Phase 2, exactly (decided 2026-09-29, TF-001):
#
#   1. Credentials — the owner provides a **bucket-scoped** R2 S3 token (Object Read & Write) for
#      `vps-tfstate` ONLY. Do not use the backup bucket's token here and do not use an account-wide
#      admin token: the two are separate by design, and neither is ever committed.
#        export AWS_ACCESS_KEY_ID=...        # from the owner, out of band
#        export AWS_SECRET_ACCESS_KEY=...
#   2. Uncomment the block above and replace `<account-id>` (the endpoint is not a secret, but it is
#      per-account, so it is not written down here).
#   3. terraform init -migrate-state        # local -> R2, carrying the existing state with it
#   4. terraform plan                       # must show NO changes; that is this task's validation
#   5. Back up the local state file offline before deleting it, then delete `terraform.tfstate*`
#      (gitignored, and it holds resource IDs and possibly sensitive attributes).
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

terraform {
  # Phase 2, switched 2026-09-29 (TF-001): state lives in the `vps-tfstate` R2 bucket, which this
  # configuration itself creates (it is in state, so the chicken/egg the earlier comments describe is
  # resolved). Credentials are the bucket-scoped S3 token, read from AWS_ACCESS_KEY_ID /
  # AWS_SECRET_ACCESS_KEY in the environment -- never in this file, never in a committed .tfvars.
  backend "s3" {
    bucket = "vps-tfstate"
    key    = "vps/terraform.tfstate"
    region = "auto"
    endpoints = {
      s3 = "https://92454a06150c83347f179e1b10f6ab35.r2.cloudflarestorage.com"
    }
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    use_lockfile                = true
  }
}
