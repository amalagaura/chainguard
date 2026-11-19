terraform {
  required_version = ">= 1.6.0"

  required_providers {
    chainguard = {
      source  = "chainguard-dev/chainguard"
      version = "~> 0.6.0"
    }

    # data.external runs scripts/mint-jwt.sh during plan and apply.
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
  }
}
