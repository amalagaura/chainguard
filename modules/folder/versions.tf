terraform {
  required_version = ">= 1.6.0"

  required_providers {
    chainguard = {
      source  = "chainguard-dev/chainguard"
      version = "~> 0.6.0"
    }
  }
}
