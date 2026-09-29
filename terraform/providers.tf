# Credentials: `HCLOUD_TOKEN`, `CLOUDFLARE_API_TOKEN` (and optionally
# `TF_VAR_cloudflare_access_api_token`) from the environment.
#
# Status 2026-09-29: the secrets file of the paragraph below **now exists** — moved out of the
# repository by OD-10 to `~/.config/vps/terraform/secrets.enc.env`, consumed by `scripts/tf.sh` through
# `sops exec-env`. Plans and applies run from this checkout. The 2026-09-28 note is kept verbatim
# below because it explains *why* the file lives where it does; read it as history, not as current
# state. (Leaving it as the opening claim is how a reader concludes "plan cannot run" about a
# directory that plans fine — the same defect class as the `backend.tf` header.)
#
# Status 2026-09-28 (CLEAN-002), historical: SOPS/age (S5) is live, but the secrets file did **not**
# exist yet — so in practice **`terraform plan` cannot run at all** from a workstation that has not
# been given those two tokens. That was measured, not assumed: the hcloud provider stopped with
# "the Hetzner Cloud API token was not found in HCLOUD_TOKEN", and the Cloudflare provider had only an
# SSL-and-Certificates token available here, which cannot read zone settings.
#
# Never hardcode a token here or in a committed .tfvars file.

provider "hcloud" {
  # token read from HCLOUD_TOKEN env var
}

provider "cloudflare" {
  # api_token read from CLOUDFLARE_API_TOKEN env var
}

# N3: a **second, narrower** Cloudflare token, used only by the Access resources in `access.tf`.
#
# Why an alias instead of one token: measured 2026-09-29, the token the owner created for Access is
# Access-only — it authorizes `GET /zones/<zone>/access/apps` but is refused on `GET
# /accounts/<id>/r2/buckets` and returns `9109 Unauthorized` on zone settings, both of which this
# configuration manages (`cloudflare_r2_bucket` ×2, `cloudflare_zone_settings_override`). Replacing
# `CLOUDFLARE_API_TOKEN` with it would have made Terraform unable to refresh resources that still
# exist — the concerning direction being a false "must be recreated", not merely an error. So the
# broad token stays where it works and Access gets its own, which is also the smaller blast radius:
# this token cannot touch R2, DNS or zone settings even if it leaks.
#
# Value comes from `TF_VAR_cloudflare_access_api_token` in the SOPS secrets file, so no credential
# ever needs to be written into a file this repository tracks.
provider "cloudflare" {
  alias     = "access"
  api_token = var.cloudflare_access_api_token
}
