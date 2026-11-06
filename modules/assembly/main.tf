variable "filename" {
  type        = string
  description = "Path of the assembly file relative to assemblies/, such as wolfi-base.yaml or custom/wolfi-base.yaml."
}

variable "raw_json" {
  type        = string
  description = "JSON encoding of the YAML document. Passing JSON keeps each file's object schema inside this module."
}

locals {
  doc  = jsondecode(var.raw_json)
  name = trimsuffix(trimsuffix(basename(var.filename), ".yaml"), ".yml")

  meta_keys = toset(["source", "tags", "description", "overlay"])

  # Both branches are strings. A conditional cannot return two object types.
  body_json = contains(keys(local.doc), "overlay") ? jsonencode(local.doc.overlay) : jsonencode({
    for key, value in local.doc : key => value if !contains(local.meta_keys, key)
  })
  body = jsondecode(local.body_json)

  # chainctl uses accounts.run-as. The overlay API requires accounts.run_as.
  run_as = try(local.body.accounts.run_as, try(local.body.accounts["run-as"], null))
  accounts_json = try(local.body.accounts, null) == null ? "{}" : jsonencode({
    accounts = merge(
      {
        for key, value in local.body.accounts :
        key => value if !contains(["run-as", "run_as"], key)
      },
      {
        for key, value in { run_as = local.run_as } :
        key => value if value != null
      },
    )
  })

  # chainctl uses a singular truststore. The overlay API requires truststores.
  truststore_value = try(local.body.truststores, null) != null ? local.body.truststores : try(local.body.truststore, null)
  truststores_json = (
    local.truststore_value == null ? "{}" :
    can(tolist(local.truststore_value)) ? jsonencode({ truststores = local.truststore_value }) :
    jsonencode({ truststores = [local.truststore_value] })
  )

  manifest = merge(
    {
      for key, value in local.body :
      key => value if !contains(["accounts", "truststore", "truststores"], key)
    },
    jsondecode(local.accounts_json),
    jsondecode(local.truststores_json),
  )

  tag_kind = lower(try(local.doc.tags.kind, "all"))
}

output "repo" {
  value = local.name
}

output "source" {
  value = try(local.doc.source, local.name)
}

output "description" {
  value = try(local.doc.description, "Custom assembly of ${try(local.doc.source, local.name)}.")
}

output "selector_kind" {
  value = lookup(
    {
      all     = "ALL"
      exact   = "EXACT"
      dev     = "VARIANT"
      variant = "VARIANT"
    },
    local.tag_kind,
    upper(local.tag_kind),
  )
}

output "selector_variant" {
  value = (
    local.tag_kind == "dev" ? "DEV" :
    try(upper(local.doc.tags.variant), "")
  )
}

output "selector_tags" {
  value = try([for tag in local.doc.tags.names : tostring(tag)], [])
}

output "overlay_json" {
  value = jsonencode(local.manifest)
}

resource "terraform_data" "repo_name" {
  input = local.name

  lifecycle {
    precondition {
      condition     = !contains(keys(local.doc), "repo") && !contains(try(keys(local.body), []), "repo")
      error_message = "Remove repo from ${var.filename}. The filename is the image repo name."
    }
  }
}
