locals {
  assembly_root = "${path.module}/assemblies"

  # assemblies/<folder>/<file>.yaml
  # <folder> is the Chainguard folder created under the organization.
  # <file> is the image repo name, unless the document sets repo.
  assembly_files = setunion(
    fileset(local.assembly_root, "*/*.yaml"),
    fileset(local.assembly_root, "*/*.yml"),
  )

  # JSON, not objects: the YAML files do not share one schema, and every
  # value in a Terraform map has to have the same type.
  assembly_raw_json = {
    for file in local.assembly_files :
    file => jsonencode(yamldecode(file("${local.assembly_root}/${file}")))
  }
}

module "assembly" {
  source   = "./modules/assembly"
  for_each = local.assembly_raw_json

  filename = each.key
  raw_json = each.value
}

locals {
  assemblies = {
    for file, assembly in module.assembly :
    file => {
      folder           = dirname(file)
      repo             = assembly.repo
      source           = assembly.source
      description      = assembly.description
      selector_kind    = assembly.selector_kind
      selector_variant = assembly.selector_variant
      selector_tags    = assembly.selector_tags
      overlay_json     = assembly.overlay_json
    }
  }

  assembly_folders = toset([for assembly in local.assemblies : assembly.folder])
}

resource "terraform_data" "assembly_check" {
  for_each = local.assemblies

  input = each.key

  lifecycle {
    precondition {
      condition = length([
        for assembly in local.assemblies : assembly
        if assembly.folder == each.value.folder && assembly.repo == each.value.repo
      ]) == 1
      error_message = "More than one file in assemblies/${each.value.folder} creates the repo ${each.value.repo}."
    }

    precondition {
      condition     = length(keys(jsondecode(each.value.overlay_json))) > 0
      error_message = "assemblies/${each.key} has an empty Custom Assembly manifest."
    }

    precondition {
      condition     = contains(["ALL", "EXACT", "VARIANT"], each.value.selector_kind)
      error_message = "assemblies/${each.key} tags.kind must be all, exact, dev, or variant."
    }

    precondition {
      condition     = each.value.selector_kind != "EXACT" || length(each.value.selector_tags) > 0
      error_message = "assemblies/${each.key} uses tags.kind exact and must set tags.names."
    }

    precondition {
      condition     = each.value.selector_kind != "VARIANT" || each.value.selector_variant != ""
      error_message = "assemblies/${each.key} uses a variant selector and must set tags.variant, or use kind dev."
    }
  }
}
