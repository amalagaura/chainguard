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
  default     = null
  description = "UIDP of the assumable identity Terraform Enterprise exchanges its workload token for. Leave null for a local chainctl login. The TF_CHAINGUARD_IDENTITY environment variable overrides this."
}

variable "chainguard_identity_token" {
  type        = string
  default     = null
  sensitive   = true
  description = "OIDC token to exchange for a Chainguard token, or a path to a file that contains one. Leave null to use the chainctl token cache. The TF_CHAINGUARD_IDENTITY_TOKEN environment variable overrides this."
}

variable "chainguard_token" {
  type        = string
  default     = null
  sensitive   = true
  description = "Chainguard access token from chainctl auth token, for the static-token agent hook. Leave null for a local chainctl login or for OIDC. This is not an OIDC token. Do not put it in chainguard_identity_token. The hook reads TF_VAR_chainguard_token or CHAINGUARD_TOKEN and writes the chainctl cache. Terraform does not send this value to the provider."
}
