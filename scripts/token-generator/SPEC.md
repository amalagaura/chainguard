---
id: token-generator
type: module-design
status: draft
title: Token generator
---

## Responsibility

Mint a Kubernetes service-account token for the pod this process runs in. An external validator has already decided that the caller may ask. This process does not identify the HTTP caller and does not choose a different account for them.

## Boundary

`POST /token` reads the projected mount at `/var/run/secrets/kubernetes.io/serviceaccount/` and calls the in-cluster TokenRequest API. It does not take a subject, a service account name, or a namespace from the request.

The name in that URL is the identity the new JWT carries. It has to be a real account this pod is allowed to mint for, so the target is the pod's own account: namespace from the `namespace` file, name from the projected token. The mounted token is only the caller credential. The default kubelet mount is a bound token, whose name lives at `kubernetes.io.serviceaccount.name`, not in its own file. Older secret tokens use `kubernetes.io/serviceaccount/service-account.name`. If neither claim is present, the name is taken from `sub` (`system:serviceaccount:<namespace>:<name>`).

Audience, lifetime, client timeout, and listen port are environment variables so a deploy can change them without rebuilding. Unset means the value this program already used: `TOKEN_AUDIENCE` `sts.amazonaws.com`, `TOKEN_EXPIRATION_SECONDS` `3600`, `TOKEN_HTTP_TIMEOUT_SECONDS` `15`, `TOKEN_PORT` `8080`. A non-positive number refuses to start. An empty string is treated as unset, because the process cannot tell an empty value from a missing one.

The API host stays `https://kubernetes.default.svc`. Granting this pod permission to create a token for its own service account is cluster configuration, not this program.
