# Chainguard Custom Assembly

Terraform syncs the Custom Assembly YAML files in `assemblies/` into a Chainguard organization. A file directly in `assemblies/` becomes an image repo in the organization. A subdirectory becomes a Chainguard folder, and each file in it becomes an image repo in that folder. Every repo is synced from a catalog image, and the YAML is bound to that repo as a Custom Assembly overlay.

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
| `overlay` | Custom Assembly manifest. When omitted, the rest of the file is the manifest | `chainguard_image_overlay.config` |
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

## What an apply creates

For a file directly in `assemblies/`:

1. An image repo whose parent is the organization, synced from `source`.
2. An organization-level overlay named `<name>`.
3. A binding from that overlay to that repo.

For a file in a directory, `chainctl` needs two commands because the folder has to exist before the repo can use it as `--parent`. Apply follows that order:

1. A folder under the organization, shared by every file in that directory. This is `chainctl iam groups create <folder> --parent <organization>`.
2. An image repo whose parent is that folder, synced from `source`. This is `chainctl images repos create <name> --parent <folder> --source <source>`. The repo's `parent_id` is the folder id, so Terraform creates the folder first.
3. An organization-level overlay named `<folder>--<name>`.
4. A binding from that overlay to that repo.

Changing an overlay replaces it. Chainguard deletes the overlay and creates it again, and the binding is replaced with it, so a production tag can rebuild twice. Read the plan before applying a change to a repo that is already in use.

A repo cannot carry a standard Custom Assembly configuration and an overlay binding at the same time. These files are the overlay. Do not also run `chainctl images repos build apply` against the same repo.

The provider does not support an all-repos binding. Each file binds one repo. A directory does not apply one manifest to every repo in the folder.

Image repos ignore `active_tags`, `bundles`, `tier`, and `readme` after create. Catalog sync owns those fields.

## Authentication

The provider block sets no browser login and no organization id. Credentials come from the environment.

### Local starter plan

The starter plan has no assumable identity, so use a Chainguard token from `chainctl`. The provider reads the token `chainctl auth login` caches. Leave `chainguard_identity_id` and `chainguard_identity_token` unset.

```shell
chainctl auth login
cp terraform.tfvars.example terraform.tfvars
# edit organization
terraform init
terraform plan
```

`terraform.tfvars` is gitignored. Do not commit a token. There is no provider argument for a raw Chainguard access token. `chainctl auth login` is the supported way to supply one. `chainctl auth token` prints the cached token so you can confirm which identity will run the plan.

A headless machine that already has a token can copy the `chainctl` config directory from a machine that logged in. Do not put that token in `tfvars`.

### Terraform Enterprise OIDC

Create the assumable identity once, with a user who can administer the corporate organization. This module does not create it. The apply that syncs assemblies assumes the identity, so the identity has to exist first.

Match the identity to the Terraform Enterprise workload token:

```hcl
resource "chainguard_identity" "tfe" {
  parent_id = data.chainguard_group.org.id
  name      = "tfe-custom-assembly"

  claim_match {
    issuer   = "https://tfe.example.com"          # Terraform Enterprise URL, no trailing slash
    audience = "https://issuer.enforce.dev"       # same value as TFC_WORKLOAD_IDENTITY_AUDIENCE
    subject_pattern = "organization:<org>:project:<project>:workspace:<workspace>:run_phase:*"
  }
}
```

Bind a role that can create folders, image repos, and overlays. The built-in `owner` role can. Narrow it to a custom role after the first successful apply shows which API calls the run makes. `editor` includes `registry.overlays.edit` and is not always enough to create a folder.

On the workspace:

| Environment variable | Value |
| --- | --- |
| `TFC_WORKLOAD_IDENTITY_AUDIENCE` | `https://issuer.enforce.dev` |
| `CHAINGUARD_IDENTITY_ID` | UIDP of the assumable identity |

Set both agent hooks to `examples/tfe-agent-hook.sh`:

* `TFC_AGENT_HOOK_PRE_PLAN`
* `TFC_AGENT_HOOK_PRE_APPLY`

The hook copies `TFC_WORKLOAD_IDENTITY_TOKEN` to `TF_CHAINGUARD_IDENTITY_TOKEN` and `CHAINGUARD_IDENTITY_ID` to `TF_CHAINGUARD_IDENTITY`. The provider reads those two variables itself. Terraform configuration cannot read `TFC_WORKLOAD_IDENTITY_TOKEN` directly, which is why the hook exists.

Set the Terraform variable `organization` on the workspace. Leave the identity variables unset when the hook exports the environment variables.

A VCS-driven workspace does not need a backend block. For CLI-driven runs against Terraform Enterprise, add a `backend "remote"` block locally and pass the hostname, organization, and workspace with `-backend-config`. Do not commit that block with a real hostname.

An air-gapped Terraform Enterprise installation needs `chainguard-dev/chainguard` in its provider mirror. This repo does not vendor the provider. Commit the lock file `.terraform.lock.hcl` after `terraform init` so the mirror and the agents resolve the same build.

`login_options.disabled` stays unset. The provider skips the token exchange when automatic login is disabled, so a Terraform Enterprise run would fail before it could use the workload token.

## Local plan without applying

`terraform validate` checks the configuration. `terraform plan` contacts Chainguard, which requires the organization name and a token. The example manifests use `wolfi-base` and `busybox`. The organization must be entitled to those catalog images, and Custom Assembly overlays must be enabled. A starter organization may not have overlays. The corporate organization is the one this module is written for.

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
| `modules/assembly/` | Maps one YAML document to a repo name, tag selector, and overlay JSON |
| `main.tf` | Folder, repo, overlay, and binding |
| `providers.tf` | Token or Terraform Enterprise identity |
| `examples/tfe-agent-hook.sh` | Copies the workload token into the variables the provider reads |
