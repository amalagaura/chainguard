#!/bin/sh
# Read a Chainguard access token from Vault KV v2 during terraform plan and apply.
#
# Terraform Enterprise dynamic credentials inject the Vault address, role, and
# workload JWT. This script logs in, reads one KV v2 field, and writes the
# chainctl cache file oidc-token. The Chainguard provider has no access-token
# argument and reads that file when identity_id and identity_token are unset.
#
# Stdout is only {"ready":"true","console_api":"..."}. The token, the workload
# JWT, and the rest of the Vault secret are not printed and are not returned
# to Terraform, so they are not stored in state.
#
# Leave the agent hooks unset. Do not set TF_CHAINGUARD_IDENTITY or
# TF_CHAINGUARD_IDENTITY_TOKEN. The workload JWT is only for the Vault login.

set -eu

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

if [ -n "${TF_CHAINGUARD_IDENTITY_TOKEN:-}" ] || [ -n "${TF_CHAINGUARD_IDENTITY:-}" ]; then
  fail "Vault runtime route refuses Chainguard OIDC settings. Unset TF_CHAINGUARD_IDENTITY and TF_CHAINGUARD_IDENTITY_TOKEN."
fi

command -v curl >/dev/null 2>&1 || fail "curl is required to read the Chainguard token from Vault."
command -v jq >/dev/null 2>&1 || fail "jq is required to read the Chainguard token from Vault."
command -v openssl >/dev/null 2>&1 || fail "openssl is required to read the Chainguard token from Vault."

query=$(cat)
mount=$(printf '%s' "$query" | jq -r '.mount // empty') || fail "Vault query was not JSON."
secret=$(printf '%s' "$query" | jq -r '.secret // empty') || fail "Vault query was not JSON."
key=$(printf '%s' "$query" | jq -r '.key // empty') || fail "Vault query was not JSON."

mount=$(printf '%s' "$mount" | sed 's|^/*||; s|/*$||')
secret=$(printf '%s' "$secret" | sed 's|^/*||; s|/*$||')
key=$(printf '%s' "$key" | sed 's|^/*||; s|/*$||')

# Mount, secret, and key become parts of a URL or a jq lookup. Keep them to
# a single path segment sequence so they cannot retarget the request.
for part in "$mount" "$secret" "$key"; do
  case "$part" in
    "" | *[!A-Za-z0-9._/-]* | *..*)
      fail "chainguard_vault_mount, chainguard_vault_secret, and chainguard_vault_key must be non-empty paths."
      ;;
  esac
done

addr=${VAULT_ADDR:-${TFC_VAULT_ADDR:-}}
addr=$(printf '%s' "$addr" | sed 's|/*$||')
[ -n "$addr" ] || fail "VAULT_ADDR is empty. Set TFC_VAULT_ADDR on the workspace."
case "$addr" in
  http://* | https://*) ;;
  *) fail "VAULT_ADDR must start with http:// or https://." ;;
esac

ns=${VAULT_NAMESPACE:-${TFC_VAULT_NAMESPACE:-}}
auth_path=${TFC_VAULT_AUTH_PATH:-jwt}
auth_path=$(printf '%s' "$auth_path" | sed 's|^/*||; s|/*$||')
case "$auth_path" in
  "" | *[!A-Za-z0-9._/-]* | *..*)
    fail "TFC_VAULT_AUTH_PATH must be a Vault auth mount path."
    ;;
esac

umask 077
tmpdir=$(mktemp -d) || fail "Cannot create a temporary directory."
trap 'rm -rf "$tmpdir"' EXIT

ca_file=""
if [ -n "${TFC_VAULT_ENCODED_CACERT:-}" ]; then
  if ! printf '%s' "$TFC_VAULT_ENCODED_CACERT" | tr -d '\n\r' | openssl base64 -d -A > "$tmpdir/ca.pem" 2>/dev/null; then
    fail "TFC_VAULT_ENCODED_CACERT is not valid base64."
  fi
  if ! grep -q -- '-----BEGIN ' "$tmpdir/ca.pem"; then
    fail "TFC_VAULT_ENCODED_CACERT is not a PEM certificate."
  fi
  ca_file="$tmpdir/ca.pem"
fi

# Vault error strings are safe to show. A string that contains the workload
# JWT is replaced so the token cannot land in the Terraform error log.
redact() {
  if [ -z "${TFC_WORKLOAD_IDENTITY_TOKEN:-}" ]; then
    printf '%s' "$1"
    return
  fi
  printf '%s' "$1" | jq -rRs 'if contains(env.TFC_WORKLOAD_IDENTITY_TOKEN) then "Vault rejected the request." else rtrimstr("\n") end'
}

vault_errors() {
  jq -r '
    if (.errors | type) == "array" then
      [.errors[] | select(type == "string")] | join("; ")
    else
      empty
    end
  ' "$1" 2>/dev/null || true
}

# Header file keeps the Vault token off the curl command line.
write_headers() {
  {
    printf 'X-Vault-Token: %s\n' "$1"
    if [ -n "$ns" ]; then
      printf 'X-Vault-Namespace: %s\n' "$ns"
    fi
  } > "$tmpdir/headers"
}

vault_curl() {
  if [ -n "$ca_file" ]; then
    curl -sS --fail-with-body --cacert "$ca_file" -H @"$tmpdir/headers" "$@"
  else
    curl -sS --fail-with-body -H @"$tmpdir/headers" "$@"
  fi
}

if [ -n "${TFC_WORKLOAD_IDENTITY_TOKEN:-}" ]; then
  payload=$(jq -nr 'env.TFC_WORKLOAD_IDENTITY_TOKEN | split(".")[1] // empty')
  phase=""
  if [ -n "$payload" ]; then
    decoded=$(printf '%s' "$payload" | tr '_-' '/+')
    case $((${#decoded} % 4)) in
      2) decoded="${decoded}==" ;;
      3) decoded="${decoded}=" ;;
    esac
    phase=$(printf '%s' "$decoded" | openssl base64 -d -A 2>/dev/null | jq -r '.terraform_run_phase // empty' 2>/dev/null || true)
  fi

  run_role=${TFC_VAULT_RUN_ROLE:-}
  case "$phase" in
    plan) role=${TFC_VAULT_PLAN_ROLE:-$run_role} ;;
    apply) role=${TFC_VAULT_APPLY_ROLE:-$run_role} ;;
    *) role=$run_role ;;
  esac
  [ -n "$role" ] || fail "TFC_VAULT_RUN_ROLE is empty."

  # jq reads the JWT from the environment, not from an argument.
  jq -n --arg role "$role" '{role:$role, jwt:env.TFC_WORKLOAD_IDENTITY_TOKEN}' > "$tmpdir/login.json"

  if [ -n "$ns" ]; then
    # Namespace is not a secret. Pass it as a header without the Vault token.
    ns_header="$tmpdir/ns-header"
    printf 'X-Vault-Namespace: %s\n' "$ns" > "$ns_header"
    if [ -n "$ca_file" ]; then
      login_ok=0
      curl -sS --fail-with-body --cacert "$ca_file" -H @"$ns_header" -H "Content-Type: application/json" \
        --data-binary @"$tmpdir/login.json" \
        "$addr/v1/auth/$auth_path/login" > "$tmpdir/login-resp.json" || login_ok=$?
    else
      login_ok=0
      curl -sS --fail-with-body -H @"$ns_header" -H "Content-Type: application/json" \
        --data-binary @"$tmpdir/login.json" \
        "$addr/v1/auth/$auth_path/login" > "$tmpdir/login-resp.json" || login_ok=$?
    fi
  else
    login_ok=0
    if [ -n "$ca_file" ]; then
      curl -sS --fail-with-body --cacert "$ca_file" -H "Content-Type: application/json" \
        --data-binary @"$tmpdir/login.json" \
        "$addr/v1/auth/$auth_path/login" > "$tmpdir/login-resp.json" || login_ok=$?
    else
      curl -sS --fail-with-body -H "Content-Type: application/json" \
        --data-binary @"$tmpdir/login.json" \
        "$addr/v1/auth/$auth_path/login" > "$tmpdir/login-resp.json" || login_ok=$?
    fi
  fi

  if [ "$login_ok" -ne 0 ]; then
    detail=$(redact "$(vault_errors "$tmpdir/login-resp.json")")
    if [ -n "$detail" ]; then
      fail "Vault JWT login failed: $detail"
    fi
    fail "Vault JWT login failed."
  fi

  vault_token=$(jq -r 'if (.auth.client_token | type) == "string" then .auth.client_token else empty end' "$tmpdir/login-resp.json")
  [ -n "$vault_token" ] || fail "Vault JWT login returned no client token."
elif [ -n "${VAULT_TOKEN:-}" ]; then
  vault_token=$VAULT_TOKEN
else
  fail "TFC_WORKLOAD_IDENTITY_TOKEN is empty. Set TFC_VAULT_PROVIDER_AUTH=true so Terraform Enterprise injects a workload JWT."
fi

write_headers "$vault_token"
read_ok=0
vault_curl "$addr/v1/$mount/data/$secret" > "$tmpdir/secret.json" || read_ok=$?
if [ "$read_ok" -ne 0 ]; then
  detail=$(redact "$(vault_errors "$tmpdir/secret.json")")
  if [ -n "$detail" ]; then
    fail "Vault read of $mount/$secret failed: $detail"
  fi
  fail "Vault read of $mount/$secret failed."
fi

kind=$(jq -r --arg key "$key" '
  if (.data.data | type) != "object" then "shape"
  elif (.data.data | has($key) | not) then "missing"
  elif (.data.data[$key] | type) != "string" then "type"
  elif (.data.data[$key] | length) == 0 then "empty"
  else "ok" end
' "$tmpdir/secret.json") || fail "Vault response for $mount/$secret was not a KV v2 secret."

case "$kind" in
  ok) ;;
  missing) fail "Vault secret $mount/$secret has no key named $key." ;;
  type | empty) fail "Vault secret $mount/$secret key $key must be a non-empty string." ;;
  *) fail "Vault response for $mount/$secret was not a KV v2 secret." ;;
esac

token=$(jq -r --arg key "$key" '.data.data[$key]' "$tmpdir/secret.json")

# Trim ends, then a single leading "Bearer ". The cache stores the raw JWT.
token=$(printf '%s' "$token" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
case "$token" in
  [Bb][Ee][Aa][Rr][Ee][Rr]\ *) token=${token#* } ;;
esac
token=$(printf '%s' "$token" | sed 's/[[:space:]]*$//')
[ -n "$token" ] || fail "Vault secret $mount/$secret key $key is empty after removing whitespace."

if printf '%s' "$token" | grep -q '[[:cntrl:]]'; then
  fail "Vault secret $mount/$secret key $key contains control characters."
fi

audience=${CHAINGUARD_AUDIENCE:-${CHAINGUARD_CONSOLE_API:-https://console-api.enforce.dev}}
# Match chainguard.dev/sdk/auth/token audienceDir: slash becomes hyphen.
audience_dir=$(printf '%s' "$audience" | sed 's|/|-|g')

if [ -n "${CHAINGUARD_TOKEN_CACHE:-}" ]; then
  cache=$CHAINGUARD_TOKEN_CACHE
else
  case "$(uname -s)" in
    Darwin) cache="${HOME}/Library/Caches" ;;
    *) cache="${XDG_CACHE_HOME:-${HOME}/.cache}" ;;
  esac
fi

if [ -z "$cache" ] || [ "$cache" = "/.cache" ] || [ "$cache" = "/Library/Caches" ]; then
  fail "Cannot locate the Chainguard token cache. HOME is unset."
fi

dest="$cache/chainguard/$audience_dir/oidc-token"
mkdir -p "$(dirname "$dest")" || fail "Cannot create the Chainguard token cache directory."

tmp="$dest.tmp.$$"
# printf does not add a newline. A trailing newline breaks the JWT parser.
printf '%s' "$token" > "$tmp" || fail "Cannot write the Chainguard token cache."
chmod 600 "$tmp" || fail "Cannot set permissions on the Chainguard token cache."
mv "$tmp" "$dest" || fail "Cannot install the Chainguard token cache."

# Drop secret material before the process exits.
unset vault_token token TFC_WORKLOAD_IDENTITY_TOKEN VAULT_TOKEN || true

jq -nc --arg api "$audience" '{ready:"true", console_api:$api}'
