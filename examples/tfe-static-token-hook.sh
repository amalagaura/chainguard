#!/bin/sh
# Terraform Enterprise agent hook for a static Chainguard access token.
# Use this until an assumable identity and OIDC are available.
#
# The provider has no argument for this token. It reads the chainctl cache
# file oidc-token when chainguard_identity_id and chainguard_identity_token
# are unset. This hook writes that file before plan and apply.
#
# Point TFC_AGENT_HOOK_PRE_PLAN and TFC_AGENT_HOOK_PRE_APPLY at this script.
# Do not also use examples/tfe-agent-hook.sh. Do not set
# TFC_WORKLOAD_IDENTITY_AUDIENCE: Terraform Enterprise would inject an OIDC
# token, and the provider would try to exchange it instead of reading the cache.
#
# Vault should supply one of these environment variables. The value is the
# raw token printed by `chainctl auth token`, not an OIDC token and not a
# registry pull token. Refresh the Vault value before the token expires.

if [ -n "${TF_CHAINGUARD_IDENTITY_TOKEN:-}" ] || [ -n "${TFC_WORKLOAD_IDENTITY_TOKEN:-}" ] || [ -n "${TF_CHAINGUARD_IDENTITY:-}" ]; then
  echo "Static token route refuses OIDC settings. Unset TF_CHAINGUARD_IDENTITY, TF_CHAINGUARD_IDENTITY_TOKEN, and TFC_WORKLOAD_IDENTITY_AUDIENCE." >&2
  exit 1
fi

token="${CHAINGUARD_TOKEN:-${TF_VAR_chainguard_token:-}}"
if [ -z "$token" ]; then
  echo "CHAINGUARD_TOKEN is empty. Set it to the output of: chainctl auth token" >&2
  exit 1
fi

# Trim ends, then a single leading "Bearer ". The cache stores the raw JWT.
token=$(printf '%s' "$token" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
case "$token" in
  [Bb][Ee][Aa][Rr][Ee][Rr]\ *) token=${token#* } ;;
esac
token=$(printf '%s' "$token" | sed 's/[[:space:]]*$//')

if [ -z "$token" ]; then
  echo "CHAINGUARD_TOKEN is empty after removing whitespace." >&2
  exit 1
fi

audience="${CHAINGUARD_AUDIENCE:-${CHAINGUARD_CONSOLE_API:-https://console-api.enforce.dev}}"
# Match chainguard.dev/sdk/auth/token audienceDir: slash becomes hyphen.
audience_dir=$(printf '%s' "$audience" | sed 's|/|-|g')

if [ -n "${CHAINGUARD_TOKEN_CACHE:-}" ]; then
  cache="$CHAINGUARD_TOKEN_CACHE"
else
  case "$(uname -s)" in
    Darwin) cache="${HOME}/Library/Caches" ;;
    *) cache="${XDG_CACHE_HOME:-${HOME}/.cache}" ;;
  esac
fi

if [ -z "$cache" ] || [ "$cache" = "/.cache" ] || [ "$cache" = "/Library/Caches" ]; then
  echo "Cannot locate the Chainguard token cache. HOME is unset." >&2
  exit 1
fi

dest="$cache/chainguard/$audience_dir/oidc-token"
mkdir -p "$(dirname "$dest")" || exit 1

umask 077
tmp="$dest.tmp.$$"
# printf does not add a newline. A trailing newline breaks the JWT parser.
printf '%s' "$token" > "$tmp" || exit 1
chmod 600 "$tmp" || exit 1
mv "$tmp" "$dest" || exit 1
