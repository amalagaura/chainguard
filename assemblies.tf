locals {
  assembly_root = "${path.module}/assemblies"

  # assemblies/<name>.yaml is a repo in the organization, with no folder.
  # assemblies/<folder>/<name>.yaml is a repo in that folder.
  # .yml is accepted as well. The Terraform key has no extension:
  # <name>, or <folder>/<name>.
  assembly_files = setunion(
    fileset(local.assembly_root, "*.yaml"),
    fileset(local.assembly_root, "*.yml"),
    fileset(local.assembly_root, "*/*.yaml"),
    fileset(local.assembly_root, "*/*.yml"),
  )

  # Same stem rule as modules/assembly. .yaml and .yml for one name share an id.
  assembly_ids = {
    for file in local.assembly_files :
    file => (
      dirname(file) == "." ?
      trimsuffix(trimsuffix(basename(file), ".yaml"), ".yml") :
      "${dirname(file)}/${trimsuffix(trimsuffix(basename(file), ".yaml"), ".yml")}"
    )
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
      folder           = dirname(local.assembly_file[id]) == "." ? null : dirname(local.assembly_file[id])
      repo             = assembly.repo
      source           = assembly.source
      description      = assembly.description
      selector_kind    = assembly.selector_kind
      selector_variant = assembly.selector_variant
      selector_tags    = assembly.selector_tags
      has_overlay      = assembly.has_overlay
      has_tags         = assembly.has_tags
      overlay_json     = assembly.overlay_json
    }
  }

  assembly_folders = toset([
    for assembly in local.assemblies : assembly.folder
    if assembly.folder != null
  ])
}

resource "terraform_data" "assembly_id" {
  for_each = local.assembly_files_by_id

  input = each.key

  lifecycle {
    precondition {
      condition     = length(each.value) == 1
      error_message = "More than one file in ${dirname(each.key) == "." ? "assemblies" : "assemblies/${dirname(each.key)}"} creates the repo ${basename(each.key)}: ${join(", ", formatlist("assemblies/%s", each.value))}."
    }
  }
}

resource "terraform_data" "assembly_check" {
  for_each = local.assemblies

  input = each.key

  lifecycle {
    precondition {
      condition = (
        each.value.folder == null ?
        each.key == each.value.repo :
        each.key == "${each.value.folder}/${each.value.repo}"
      )
      error_message = "assemblies/${each.value.file} resolved to repo ${each.value.repo} under ${each.value.folder == null ? "the organization" : "folder ${each.value.folder}"}, which does not match Terraform key ${each.key}."
    }

    precondition {
      condition     = each.value.has_overlay || !each.value.has_tags
      error_message = "assemblies/${each.value.file} sets tags but has no Custom Assembly manifest to bind."
    }

    precondition {
      condition     = !each.value.has_overlay || contains(["ALL", "EXACT", "VARIANT"], each.value.selector_kind)
      error_message = "assemblies/${each.value.file} tags.kind must be all, exact, dev, or variant."
    }

    precondition {
      condition     = !each.value.has_overlay || each.value.selector_kind != "EXACT" || length(each.value.selector_tags) > 0
      error_message = "assemblies/${each.value.file} uses tags.kind exact and must set tags.names."
    }

    precondition {
      condition     = !each.value.has_overlay || each.value.selector_kind != "VARIANT" || each.value.selector_variant != ""
      error_message = "assemblies/${each.value.file} uses a variant selector and must set tags.variant, or use kind dev."
    }
  }
}
