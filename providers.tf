provider "chainguard" {
  # Both attributes stay unset on a laptop. The provider then uses the token
  # chainctl cached. On Terraform Enterprise, set TF_CHAINGUARD_IDENTITY and
  # TF_CHAINGUARD_IDENTITY_TOKEN (see README). Those environment variables
  # win over these arguments, and an identity token is exclusive with the
  # browser login options, so this block does not set any of those.
  login_options {
    identity_id    = var.chainguard_identity_id
    identity_token = var.chainguard_identity_token
  }
}
