# Credentials: `HCLOUD_TOKEN` and `CLOUDFLARE_API_TOKEN` from the environment.
#
# Status 2026-09-28 (CLEAN-002): SOPS/age (S5) is live, but `terraform/secrets.enc.env` does **not**
# exist yet — so in practice **`terraform plan` cannot run at all** from a workstation that has not
# been given those two tokens. That was measured, not assumed: the hcloud provider stops with
# "the Hetzner Cloud API token was not found in HCLOUD_TOKEN", and the Cloudflare provider has only an
# SSL-and-Certificates token available here, which cannot read zone settings.
#
# Consequence, recorded so it is not mistaken for a code problem: any plan/apply in this directory
# needs the owner to place a Hetzner API token (and, for DNS/zone work, a Cloudflare token with the
# matching scopes) on the machine first. `terraform validate` and `fmt` need no credentials.
#
# The intended home for them is `terraform/secrets.enc.env` (SOPS; the creation rule already exists in
# `.sops.yaml`) consumed via `sops exec-env` — that file is TF-001's input, which is why the rule is
# kept rather than removed. Never hardcode a token here or in a committed .tfvars file.

provider "hcloud" {
  # token read from HCLOUD_TOKEN env var
}

provider "cloudflare" {
  # api_token read from CLOUDFLARE_API_TOKEN env var
}
