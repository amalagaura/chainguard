---
id: token-generator
type: module-design
status: draft
title: Token generator
---

## Responsibility

Mint a Kubernetes service-account token for an account the caller names. An external validator has already decided that the caller may ask. This process does not identify the HTTP caller. Kubernetes RBAC on `serviceaccounts/token`, decides which accounts that pod may mint for.

## Boundary

`POST /token` takes a JSON body. `name`, `audience`, and `expiration_seconds` are required. A missing name or audience, a name that is not a service account name, or an expiration that is not a positive integer is rejected before any call to the API server. The name is the account in the TokenRequest URL, and that name is the subject of the new JWT. The audience and lifetime are the TokenRequest spec. They are not process configuration.

The namespace is the pod's projected `namespace` file. The caller cannot name another namespace. The mounted token is only the caller credential. It is not parsed for an account name.

`TOKEN_PORT` and `TOKEN_HTTP_TIMEOUT_SECONDS` remain environment variables, defaulting to `8080` and `15` when unset. A bad number refuses to start.

The API host stays `https://kubernetes.default.svc`. A minted token is not bound to this pod. Granting `create` on `serviceaccounts/token` is cluster configuration. An empty `resourceNames` list lets this pod mint for every account in the namespace.
