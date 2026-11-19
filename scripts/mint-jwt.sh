#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./mint-jwt.sh <private_key.pem> [issuer] [audience] [subject] [ttl_seconds] [output_path]
# Example:
#   ./mint-jwt.sh private.pem https://my-issuer.example.com my-aud my-subject 3600
#   ./mint-jwt.sh private.pem https://my-issuer.example.com my-aud my-subject 3600 token.jwt
#
# With no output path, the JWT is printed. With an output path, the JWT is
# written to that file and stdout is {"token_file":"<path>"}. Terraform stores
# stdout in state, so the token stays in the file.

if [[ $# -lt 1 ]]; then
	echo "Usage: $0 <private_key.pem> [issuer] [audience] [subject] [ttl_seconds] [output_path]" >&2
	exit 1
fi

PRIVATE_KEY="$1"
ISS="${2:-https://example-issuer.local}"
AUD="${3:-example-audience}"
SUB="${4:-example-subject}"
TTL="${5:-3600}"
OUTPUT_PATH="${6:-}"

if [[ -n "$OUTPUT_PATH" ]]; then
	if [[ "$ISS" != https://* || "$ISS" == */ ]]; then
		echo "Error: issuer must be an https URL with no trailing slash." >&2
		exit 1
	fi
	if [[ -z "$AUD" || -z "$SUB" ]]; then
		echo "Error: audience and subject are required when writing a token file." >&2
		exit 1
	fi
	if [[ ! "$TTL" =~ ^[0-9]+$ || "$TTL" -lt 1 ]]; then
		echo "Error: ttl must be a whole number of seconds." >&2
		exit 1
	fi
fi

if [[ ! -f "$PRIVATE_KEY" ]]; then
	echo "Error: private key file not found: $PRIVATE_KEY" >&2
	exit 1
fi

command -v jq >/dev/null 2>&1 || {
	echo "Error: jq is required to build the JWT payload." >&2
	exit 1
}
command -v openssl >/dev/null 2>&1 || {
	echo "Error: openssl is required to sign the JWT." >&2
	exit 1
}

NOW=$(date +%s)
EXP=$((NOW + TTL))
JTI=$(uuidgen 2>/dev/null || echo "$RANDOM-$NOW")

HEADER=$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | openssl base64 -A | tr '+/' '-_' | tr -d '=')

PAYLOAD_JSON=$(jq -nc \
	--arg iss "$ISS" \
	--arg aud "$AUD" \
	--arg sub "$SUB" \
	--arg jti "$JTI" \
	--argjson iat "$NOW" \
	--argjson nbf "$NOW" \
	--argjson exp "$EXP" \
	'{iss:$iss,aud:$aud,sub:$sub,iat:$iat,nbf:$nbf,exp:$exp,jti:$jti}')

PAYLOAD=$(printf '%s' "$PAYLOAD_JSON" | openssl base64 -A | tr '+/' '-_' | tr -d '=')

SIGNING_INPUT="${HEADER}.${PAYLOAD}"
SIGNATURE=$(printf '%s' "$SIGNING_INPUT" |
	openssl dgst -sha256 -sign "$PRIVATE_KEY" -binary |
	openssl base64 -A |
	tr '+/' '-_' |
	tr -d '=')

JWT="${SIGNING_INPUT}.${SIGNATURE}"

if [[ -z "$OUTPUT_PATH" ]]; then
	echo "$JWT"
	exit 0
fi

mkdir -p "$(dirname "$OUTPUT_PATH")"
umask 077
tmp="${OUTPUT_PATH}.tmp.$$"
printf '%s' "$JWT" > "$tmp"
chmod 600 "$tmp"
mv "$tmp" "$OUTPUT_PATH"
jq -nc --arg token_file "$OUTPUT_PATH" '{token_file:$token_file}'
