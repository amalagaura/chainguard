variable "filename" {
  type        = string
  description = "Path of the assembly file relative to assemblies/, such as wolfi-base.yaml or custom/wolfi-base.yaml."
}

variable "raw_json" {
  type        = string
  description = "JSON encoding of the YAML document. Passing JSON keeps each file's object schema inside this module."
}

variable "include_raw_jsons" {
  type        = list(string)
  default     = []
  description = "JSON encoding of each file listed in include, in that order."
}

variable "include_paths" {
  type        = list(string)
  default     = []
  description = "Repository-relative paths of include_raw_jsons, used when a fragment is not a manifest."
}

locals {
  name             = trimsuffix(trimsuffix(basename(var.filename), ".yaml"), ".yml")
  image_is_mapping = can(keys(jsondecode(var.raw_json)))
  tag_kind         = lower(try(jsondecode(var.raw_json).tags.kind, "all"))
}

output "repo" {
  value = local.name
}

output "source" {
  value = try(jsondecode(var.raw_json).source, local.name)
}

output "description" {
  value = try(
    jsondecode(var.raw_json).description,
    local.has_manifest ? "Custom assembly of ${try(jsondecode(var.raw_json).source, local.name)}." : "Sync of ${try(jsondecode(var.raw_json).source, local.name)}.",
  )
}

output "has_overlay" {
  value = local.has_manifest
}

output "has_tags" {
  value = local.image_is_mapping ? contains(keys(jsondecode(var.raw_json)), "tags") : false
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
    try(upper(jsondecode(var.raw_json).tags.variant), "")
  )
}

output "selector_tags" {
  value = try([for tag in jsondecode(var.raw_json).tags.names : tostring(tag)], [])
}

output "overlay_json" {
  value = local.overlay_json
}

resource "terraform_data" "repo_name" {
  input = local.name

  lifecycle {
    precondition {
      condition     = module.image_document.valid
      error_message = module.image_document.error
    }
    precondition {
      condition     = !local.any_repo
      error_message = "Remove repo from ${var.filename}. The filename is the image repo name."
    }
  }
}

resource "terraform_data" "fragments" {
  count = length(var.include_raw_jsons) == 0 && length(var.include_paths) == 0 ? 0 : 1

  lifecycle {
    precondition {
      condition     = local.fragments_ok
      error_message = local.fragment_error_message
    }
  }
}
