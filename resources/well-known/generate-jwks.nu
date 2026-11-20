#!/usr/bin/env nu

# Print a JWKS document for an RSA public key.
# Usage: nu resources/well-known/generate-jwks.nu public.pem

def b64url [hex: string] {
  let even = if (($hex | str length) mod 2) == 1 { $"0($hex)" } else { $hex }
  $even | decode hex | encode base64 --url --nopad
}

def main [public_pem: string] {
  let modulus = (^openssl rsa -pubin -in $public_pem -modulus -noout | str replace "Modulus=" "" | str trim | str lowercase)
  let exponent_hex = (
    ^openssl rsa -pubin -in $public_pem -text -noout
    | lines
    | where {|line| $line =~ "Exponent:"}
    | first
    | parse --regex '0x(?<hex>[0-9a-fA-F]+)'
    | get hex.0
    | str lowercase
  )
  {
    keys: [{
      kty: "RSA"
      use: "sig"
      alg: "RS256"
      kid: "1"
      n: (b64url $modulus)
      e: (b64url $exponent_hex)
    }]
  } | to json --indent 2
}
