# 1. Generate the private key (keep this secret — never put it in S3)
openssl genrsa -out private.pem 2048

# 2. Extract the public key
openssl rsa -in private.pem -pubout -out public.pem
