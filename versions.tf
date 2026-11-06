terraform {
  required_version = ">= 1.6.0"

  required_providers {
    chainguard = {
      source  = "chainguard-dev/chainguard"
      version = "~> 0.6.0"
    }

    # data.external runs the Vault read during plan and apply. Count 0 still
    # requires the provider to be installed.
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
  }
}
