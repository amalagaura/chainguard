#!/bin/sh
# Print a JWKS document for the public half of an RSA private key.
# Pass the JSON to chainctl iam identities create --issuer-keys.

set -eu

if [ $# -ne 1 ] || [ ! -f "$1" ]; then
	echo "Usage: $0 <private_key.pem>" >&2
	exit 1
fi

openssl rsa -in "$1" -RSAPublicKey_out -outform DER 2>/dev/null | python3 -c '
import base64, json, sys

der = sys.stdin.buffer.read()

def take_len(data, i):
    n = data[i]
    i += 1
    if n < 0x80:
        return n, i
    nbytes = n & 0x7F
    length = int.from_bytes(data[i:i + nbytes], "big")
    return length, i + nbytes

def take_int(data, i):
    if data[i] != 0x02:
        raise SystemExit("public key was not an RSA integer")
    length, i = take_len(data, i + 1)
    raw = data[i:i + length]
    if raw[:1] == b"\x00":
        raw = raw[1:]
    return raw, i + length

if not der or der[0] != 0x30:
    raise SystemExit("openssl did not return an RSA public key")
_, i = take_len(der, 1)
n, i = take_int(der, i)
e, _ = take_int(der, i)

def b64url(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()

json.dump({"keys": [{"kty": "RSA", "use": "sig", "alg": "RS256", "n": b64url(n), "e": b64url(e)}]}, sys.stdout)
print()
'
