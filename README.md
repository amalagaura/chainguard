# Chainguard Custom Assembly

Terraform syncs the YAML files in `assemblies/` into a Chainguard organization. A file directly in `assemblies/` becomes an image repo in the organization. A subdirectory becomes a Chainguard folder, and each file in it becomes an image repo in that folder. Every repo is synced from a catalog image. A file that contains a Custom Assembly manifest is bound to its repo as an overlay. A file with no manifest is a plain sync.

Terraform uses the YAML files as the source of truth.

This root module is generic.  No organization id, token, or identity id is committed. That information is supplied externally.

## Mapping

```text
assemblies/<name>.yaml
assemblies/<folder>/<name>.yaml
```

| Path or key | Chainguard object | Terraform address |
| --- | --- | --- |
| `<name>.yaml` directly in `assemblies/` | Image repo in the organization. No folder is created | `chainguard_image_repo.assembly["<name>"]` |
| `<folder>/` | Folder under the organization | `chainguard_group.folder["<folder>"]` |
| `<folder>/<name>.yaml` or `.yml` | Image repo in that folder. The repo, overlay, and binding share this key | `chainguard_image_repo.assembly["<folder>/<name>"]` |
| `source` | Catalog image to sync. Set it in the file. Defaults to `<name>` | `sync_config.source` |
| `description` | Repo description. Set it in the file. Defaults to a one-line note | `description` |
| `tags` | Which tags receive the overlay. Set it in the file. Defaults to every tag | `chainguard_image_overlay_binding` |
| `overlay` | Custom Assembly manifest. When omitted, the rest of the file is the manifest. When that manifest is empty, no overlay or binding is created | `chainguard_image_overlay.config` |
| `<name>` or `<folder>--<name>` | Overlay name. Overlays belong to the organization. A folder repo includes the folder so the name stays unique | `chainguard_image_overlay.assembly["<name>"]` or `["<folder>/<name>"]` |

The filename, without `.yaml` or `.yml`, is the repo name. Folder names and repo names use Chainguard's name rules: lowercase letters, digits, and hyphens. The Terraform key has no extension: `<name>` for a file in `assemblies/`, and `<folder>/<name>` for a file in a directory. `name.yaml` and `name.yml` in the same directory are that same key, and the plan fails. The same repo name in the organization and in a folder is allowed, because the parents differ.

The pull reference printed by Terraform is `cgr.dev/<organization>/<name>`. It does not include the folder. The IAM parent is the organization for a file in `assemblies/`, and the folder for a file in a directory. Confirm the reference with `chainctl images repos list` after the first apply.

Renaming a file replaces the Terraform resource. Chainguard image repos cannot be deleted through Terraform. Remove a file only after deleting the repo with `chainctl` and dropping it from state. See [Removing an assembly](#removing-an-assembly).

### Shorthand

`assemblies/custom-assembly/wolfi-base.yaml` syncs the catalog image `wolfi-base` into the folder `custom-assembly`, under the repo name `wolfi-base`, and applies the file to every tag:

```yaml
contents:
  packages:
    - curl
    - jq
environment:
  APP_ENV: production
```

### source, description, and tags

Set `source`, `description`, and `tags` in the YAML file. The filename is the repo name.

```yaml
source: busybox
description: Busybox with curl, built from the busybox catalog image.
tags:
  kind: exact
  names:
    - latest
overlay:
  contents:
    packages:
      - curl
```

`tags.kind` is `all` (default), `exact` (requires `tags.names`), `dev` (tags that end in `-dev`), or `variant` (requires `tags.variant`, for example `DEV`).

### Manifest field names

The manifest uses the Custom Assembly API names, which the Terraform provider validates. `contents`, `environment`, `annotations`, `certificates`, `accounts.run_as`, `guarded_entrypoint`, `fail_mode`, `preflight`, and `command_override` match the API.

Terraform rewrites two `chainctl` spellings before it sends the manifest:

| In the YAML | Sent to Chainguard |
| --- | --- |
| `accounts.run-as` | `accounts.run_as` |
| `truststore` | `truststores` |

A single `truststore` object is wrapped in a list. Any other unknown field fails the plan. The provider rejects it rather than dropping it.

Do not put `source`, `tags`, or `description` inside `overlay`. A `repo` key anywhere in the file fails the plan, because the filename is the repo name.

### Shared fragments

YAML anchors stay inside one file. A shared file lives in `assembly_fragments/` and is listed from the image with `include`. Terraform merges it into that image's manifest and removes `include` before the manifest is sent. The path is relative to the repository root and starts with `assembly_fragments/`, so the file is not turned into an image repo.

```yaml
# assembly_fragments/certificates.yaml
certificates:
  additional:
    - name: internal-ca
      content: |
        -----BEGIN CERTIFICATE-----
        ...
        -----END CERTIFICATE-----
environment:
  REQUESTS_CA_BUNDLE: /etc/ssl/certs/ca-certificates.crt
```

```yaml
# assemblies/custom/wolfi-base.yaml
include:
  - assembly_fragments/certificates.yaml
contents:
  packages:
    - curl
environment:
  APP_ENV: production
```

Terraform loads each listed file into a fixed object and merges it during plan. Files are merged in the order listed, and the image file is applied last. `environment` and `annotations` combine, and the image wins on a shared key. `contents.packages`, `contents.runtime_repositories`, `contents.runtime_keyring`, `certificates.additional`, `accounts.users`, `accounts.groups`, and `preflight` are appended, fragment first. `fail_mode`, `guarded_entrypoint`, `accounts.run_as`, `command_override`, and `truststore` are replaced by the later file. A `truststore` object is sent as a one-element `truststores` list. A fragment cannot contain `include`. A key outside this set fails the plan.

## What an apply creates

A file with no manifest copies the catalog image and stops. `source` names that image. The filename is the repo name, so this file copies `wolfi-base` into the organization without an overlay:

```yaml
source: wolfi-base
```

`description` may be set. `tags` may not: tags choose which image tags receive an overlay, and this file has no overlay.

For any other file directly in `assemblies/` whose manifest is not empty:

1. An image repo whose parent is the organization, synced from `source`.
2. An organization-level overlay named `<name>`.
3. A binding from that overlay to that repo.

For a file in a directory, `chainctl` needs two commands because the folder has to exist before the repo can use it as `--parent`. Apply follows that order:

1. A folder under the organization, shared by every file in that directory. This is `chainctl iam groups create <folder> --parent <organization>`.
2. An image repo whose parent is that folder, synced from `source`. This is `chainctl images repos create <name> --parent <folder> --source <source>`. The repo's `parent_id` is the folder id, so Terraform creates the folder first.
3. When the file has a manifest, an organization-level overlay named `<folder>--<name>`.
4. When the file has a manifest, a binding from that overlay to that repo.

Changing an overlay replaces it. Chainguard deletes the overlay and creates it again, and the binding is replaced with it, so a production tag can rebuild twice. Read the plan before applying a change to a repo that is already in use.

A repo cannot carry a standard Custom Assembly configuration and an overlay binding at the same time. These files are the overlay. Do not also run `chainctl images repos build apply` against the same repo.

The provider does not support an all-repos binding. Each file binds one repo. A directory does not apply one manifest to every repo in the folder.

Image repos ignore `active_tags`, `bundles`, `tier`, and `readme` after create. Catalog sync owns those fields.

## Authentication

Plan and apply call `scripts/mint-jwt.sh` with the signing key, issuer, audience, subject, lifetime, and an output path. The script writes the JWT to `.terraform/chainguard-oidc.jwt` and prints that path. `login_options.identity_token` is the path. State records the path. The provider exchanges the token for `chainguard_identity_id`.

The three claims have to be the same values on the assumable identity. Chainguard rejects the exchange when any one differs.

| Claim | Terraform variable | What to put |
| --- | --- | --- |
| Audience | `chainguard_oidc_audience` | `https://issuer.enforce.dev` |
| Subject | `chainguard_oidc_subject` | `terraform:chainguard` |
| Issuer | `chainguard_oidc_issuer` | A URL you choose, for example `https://oidc.example.com` |

The audience is who the token is for. `https://issuer.enforce.dev` is Chainguard's STS.

The subject is who the token represents. The identity's subject has to be that exact string.

The issuer is who signed the token. It must be the URL on the identity, with no trailing slash.

Create the identity once, from an account that can create identities and role bindings.

`*.pem` is gitignored. Build the key, then the JWKS, then the identity:

```shell
openssl genrsa -out oidc-private.pem 2048
scripts/public-jwks.sh oidc-private.pem > oidc-public.jwks
chainctl iam identities create minted-custom-assembly \
  --parent "$ORGANIZATION" \
  --identity-issuer "https://oidc.example.com" \
  --issuer-keys "$(cat oidc-public.jwks)" \
  --audience "https://issuer.enforce.dev" \
  --subject "terraform:chainguard" \
  --role owner
```

Set `chainguard_identity_id` to the UIDP that command prints. The machine that runs plan and apply needs `bash`, `jq`, `openssl`, and `uuidgen`. `scripts/public-jwks.sh` also needs `python3` when you register the identity.

An air-gapped installation needs `chainguard-dev/chainguard` and `hashicorp/external` in its provider mirror. This repo does not vendor providers. Commit the lock file `.terraform.lock.hcl` after `terraform init` so every run resolves the same build.

`login_options.disabled` stays unset. The provider skips the token exchange when automatic login is disabled.

## Local plan without applying

`terraform validate` checks the configuration. `terraform plan` contacts Chainguard, which requires the organization name and a token. The organization must be entitled to those catalog images, and Custom Assembly overlays must be enabled. A starter organization may not have overlays. The corporate organization is the one this module is written for.

## Removing an assembly

1. Delete the image repo with `chainctl images repos delete <repo> --parent <parent>`. `<parent>` is the organization when the file was directly in `assemblies/`, and the folder name when the file was in a directory.
2. Remove it from state: `terraform state rm 'chainguard_image_repo.assembly["custom-assembly/wolfi-base"]'`.
3. Delete the YAML and apply. Terraform then deletes the binding and the overlay.

Deleting the YAML first makes apply fail. The image repo resource's delete is a no-op that returns an error, on purpose, so Terraform cannot drop a registry repo.

## Files

| File | Purpose |
| --- | --- |
| `assemblies/` | Custom Assembly YAML |
| `assemblies.tf` | Discovers YAML files and calls the assembly module |
| `assembly_fragments/` | Shared manifest files listed by `include`. Not image repos |
| `modules/assembly/` | Maps one YAML document to a repo name, tag selector, and overlay JSON |
| `tests/` | `terraform test -test-directory=tests`. Fixtures are inline and do not read `assemblies/` |
| `main.tf` | Folder, repo, overlay, and binding |
| `providers.tf` | Exchanges the OIDC token minted by `scripts/mint-jwt.sh` |
| `scripts/mint-jwt.sh` | Signs an OIDC JWT. Prints it, or writes it when given an output path |
| `scripts/public-jwks.sh` | Prints the JWKS to register with the assumable identity |
