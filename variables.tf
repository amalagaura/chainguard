variable "organization" {
  type        = string
  description = "Verified Chainguard organization name. The same value for every environment; do not hardcode it in the assembly YAML."

  validation {
    condition     = length(var.organization) > 0
    error_message = "Set organization to the Chainguard organization name, for example in terraform.tfvars."
  }
}

variable "chainguard_identity_id" {
  type        = string
  description = "UIDP of the assumable identity that exchanges the minted OIDC token. Register that identity with the public key from scripts/public-jwks.sh."

  validation {
    condition     = length(var.chainguard_identity_id) > 0
    error_message = "Set chainguard_identity_id to the assumable identity UIDP."
  }
}

variable "chainguard_oidc_signing_key" {
  type        = string
  description = "Path to the RSA private key PEM that scripts/mint-jwt.sh uses to sign an OIDC token during plan and apply. Do not commit the key."

  validation {
    condition     = length(var.chainguard_oidc_signing_key) > 0
    error_message = "Set chainguard_oidc_signing_key to the RSA private key PEM."
  }
}

variable "chainguard_oidc_issuer" {
  type        = string
  description = "iss claim of the minted OIDC token. The same URL as the assumable identity's issuer, with no trailing slash."

  validation {
    condition     = startswith(var.chainguard_oidc_issuer, "https://") && !endswith(var.chainguard_oidc_issuer, "/")
    error_message = "Set chainguard_oidc_issuer to an https URL with no trailing slash."
  }
}

variable "chainguard_oidc_audience" {
  type        = string
  description = "aud claim of the minted OIDC token. Use https://issuer.enforce.dev so it matches the assumable identity."

  validation {
    condition     = length(var.chainguard_oidc_audience) > 0
    error_message = "Set chainguard_oidc_audience. https://issuer.enforce.dev matches Chainguard's STS."
  }
}

variable "chainguard_oidc_subject" {
  type        = string
  description = "sub claim of the minted OIDC token. Use the exact subject registered on the assumable identity, for example terraform:chainguard."

  validation {
    condition     = length(var.chainguard_oidc_subject) > 0
    error_message = "Set chainguard_oidc_subject to the exact subject on the assumable identity."
  }
}

variable "chainguard_oidc_ttl" {
  type        = number
  default     = 3600
  description = "Lifetime in seconds of the minted OIDC token. The provider exchanges it at the start of plan and apply. Default is one hour."
}
