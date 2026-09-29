terraform {
  required_version = ">= 1.7"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.45"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0" # pinned major per the review §17 S2 — bump deliberately via PR, never float
    }
  }

  # Local backend until the `vps-tfstate` R2 bucket exists (this config creates it — chicken/egg).
  # See backend.tf and terraform/README.md "Bootstrap sequence" for the two-phase migration.
}
