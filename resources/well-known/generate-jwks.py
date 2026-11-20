#!/usr/bin/env python3
import json
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.backends import default_backend
import base64

with open("public.pem", "rb") as f:
    pub = serialization.load_pem_public_key(f.read(), backend=default_backend())

numbers = pub.public_numbers()

def b64url(n):
    b = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()

jwks = {
    "keys": [{
        "kty": "RSA",
        "use": "sig",
        "alg": "RS256",
        "kid": "1",
        "n": b64url(numbers.n),
        "e": b64url(numbers.e)
    }]
}

print(json.dumps(jwks, indent=2))
