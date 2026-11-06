# Runs only when chainguard_vault_secret is set. The script writes the chainctl
# cache and returns the console API it used. Referencing that result from the
# provider makes Configure wait until the file exists. The ternary keeps the
# query value a string when the route is off and this data source has no
# instances. coalesce is not used: it rejects null and an empty string together.
data "external" "chainguard_vault_token" {
  count = var.chainguard_vault_secret == null ? 0 : 1

  program = ["${path.module}/examples/vault-runtime-token.sh"]

  query = {
    mount  = var.chainguard_vault_mount
    secret = var.chainguard_vault_secret == null ? "" : var.chainguard_vault_secret
    key    = var.chainguard_vault_key
  }
}

provider "chainguard" {
  # Null when the Vault route is off, which leaves the provider default.
  # When the route is on, this is the audience the script used for the cache
  # directory. The reference is what orders the Vault read first.
  console_api = one(data.external.chainguard_vault_token[*].result.console_api)

  # Both identity attributes stay unset on a laptop. The provider then uses
  # the token chainctl cached. On Terraform Enterprise OIDC, set
  # TF_CHAINGUARD_IDENTITY and TF_CHAINGUARD_IDENTITY_TOKEN (see README).
  # Those environment variables win over these arguments. An identity token
  # is exclusive with the cache file, so the Vault route leaves both unset.
  # login_options.disabled stays unset so a cached token can still be read.
  login_options {
    identity_id    = var.chainguard_identity_id
    identity_token = var.chainguard_identity_token
  }
}

check "chainguard_auth_route" {
  assert {
    condition = var.chainguard_token == null || (
      var.chainguard_identity_id == null &&
      var.chainguard_identity_token == null &&
      (var.chainguard_vault_secret == null ? "" : var.chainguard_vault_secret) == ""
    )
    error_message = "chainguard_token is a Chainguard access token for examples/tfe-static-token-hook.sh. Leave chainguard_identity_id, chainguard_identity_token, and chainguard_vault_secret unset."
  }

  assert {
    # The ternary avoids length(null). Terraform evaluates both sides of ||.
    condition = (
      (var.chainguard_vault_secret == null ? "" : var.chainguard_vault_secret) == "" ||
      (
        var.chainguard_identity_id == null &&
        var.chainguard_identity_token == null &&
        var.chainguard_token == null &&
        length(var.chainguard_vault_mount) > 0 &&
        length(var.chainguard_vault_key) > 0 &&
        length(var.chainguard_vault_secret == null ? "" : var.chainguard_vault_secret) > 0
      )
    )
    error_message = "chainguard_vault_secret reads the access token from Vault during plan and apply. Leave chainguard_token, chainguard_identity_id, and chainguard_identity_token unset, and set a non-empty mount, secret path, and key. Do not use an agent hook on this route."
  }
}
