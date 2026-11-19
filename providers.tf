# Plan and apply mint an OIDC token with scripts/mint-jwt.sh. The script
# prints the file path because data.external stores stdout in state.
# The provider reads that file and exchanges it for chainguard_identity_id.
data "external" "chainguard_minted_oidc" {
  program = [
    "${path.module}/scripts/mint-jwt.sh",
    var.chainguard_oidc_signing_key,
    var.chainguard_oidc_issuer,
    var.chainguard_oidc_audience,
    var.chainguard_oidc_subject,
    tostring(var.chainguard_oidc_ttl),
    "${path.root}/.terraform/chainguard-oidc.jwt",
  ]
}

provider "chainguard" {
  login_options {
    identity_id    = var.chainguard_identity_id
    identity_token = data.external.chainguard_minted_oidc.result.token_file
  }
}
