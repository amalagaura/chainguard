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

check "chainguard_static_token" {
  assert {
    condition     = var.chainguard_token == null || (var.chainguard_identity_id == null && var.chainguard_identity_token == null)
    error_message = "chainguard_token is a Chainguard access token. Leave chainguard_identity_id and chainguard_identity_token unset, and point the agent hooks at examples/tfe-static-token-hook.sh."
  }
}
