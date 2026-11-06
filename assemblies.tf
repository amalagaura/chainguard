locals {
  assembly_root = "${path.module}/assemblies"

  # assemblies/<folder>/<name>.yaml or <folder>/<name>.yml
  # <folder> is the Chainguard folder created under the organization.
  # <name> is the image repo name. The Terraform key is <folder>/<name>,
  # so the extension is not part of the address.
  assembly_files = setunion(
    fileset(local.assembly_root, "*/*.yaml"),
    fileset(local.assembly_root, "*/*.yml"),
  )

  # Same stem rule as modules/assembly. .yaml and .yml for one name share an id.
  assembly_ids = {
    for file in local.assembly_files :
    file => "${dirname(file)}/${trimsuffix(trimsuffix(basename(file), ".yaml"), ".yml")}"
  }

  assembly_files_by_id = {
    for file, id in local.assembly_ids :
    id => file...
  }

  # Leave a duplicated id out of the resource map. The check below fails
  # the plan, and applying one of the two files would hide the other.
  assembly_file = {
    for id, files in local.assembly_files_by_id :
    id => files[0]
    if length(files) == 1
  }

  # JSON, not objects: the YAML files do not share one schema, and every
  # value in a Terraform map has to have the same type.
  assembly_raw_json = {
    for id, file in local.assembly_file :
    id => jsonencode(yamldecode(file("${local.assembly_root}/${file}")))
  }
}

module "assembly" {
  source   = "./modules/assembly"
  for_each = local.assembly_raw_json

  filename = local.assembly_file[each.key]
  raw_json = each.value
}

locals {
  assemblies = {
    for id, assembly in module.assembly :
    id => {
      file             = local.assembly_file[id]
      folder           = dirname(local.assembly_file[id])
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

resource "terraform_data" "assembly_id" {
  for_each = local.assembly_files_by_id

  input = each.key

  lifecycle {
    precondition {
      condition     = length(each.value) == 1
      error_message = "More than one file in assemblies/${dirname(each.key)} creates the repo ${basename(each.key)}: ${join(", ", formatlist("assemblies/%s", each.value))}."
    }
  }
}

resource "terraform_data" "assembly_check" {
  for_each = local.assemblies

  input = each.key

  lifecycle {
    precondition {
      condition     = each.value.repo == basename(each.key) && each.value.folder == dirname(each.key)
      error_message = "assemblies/${each.value.file} resolved to repo ${each.value.repo} in folder ${each.value.folder}, which does not match Terraform key ${each.key}."
    }

    precondition {
      condition     = length(keys(jsondecode(each.value.overlay_json))) > 0
      error_message = "assemblies/${each.value.file} has an empty Custom Assembly manifest."
    }

    precondition {
      condition     = contains(["ALL", "EXACT", "VARIANT"], each.value.selector_kind)
      error_message = "assemblies/${each.value.file} tags.kind must be all, exact, dev, or variant."
    }

    precondition {
      condition     = each.value.selector_kind != "EXACT" || length(each.value.selector_tags) > 0
      error_message = "assemblies/${each.value.file} uses tags.kind exact and must set tags.names."
    }

    precondition {
      condition     = each.value.selector_kind != "VARIANT" || each.value.selector_variant != ""
      error_message = "assemblies/${each.value.file} uses a variant selector and must set tags.variant, or use kind dev."
    }
  }
}
