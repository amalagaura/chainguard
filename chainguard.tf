data "chainguard_group" "org" {
  parent_id = "/"
  name      = var.organization
}

resource "chainguard_group" "folder" {
  for_each = local.folders_at_depth[1]

  parent_id   = data.chainguard_group.org.id
  name        = basename(each.value)
  description = "Custom Assembly images from assemblies/${each.value}."
}

# Deeper folders live in their own module so a folder can use the id of the
# folder above it. One resource cannot read another instance of itself.
module "folder_2" {
  source     = "./modules/folder"
  paths      = local.folders_at_depth[2]
  parent_ids = { for path, folder in chainguard_group.folder : path => folder.id }
}

module "folder_3" {
  source     = "./modules/folder"
  paths      = local.folders_at_depth[3]
  parent_ids = module.folder_2.ids
}

locals {
  # chainctl creates a repo under a folder in two steps: iam groups create,
  # then images repos create --parent <folder>. Each deeper folder uses the
  # folder above it as --parent. A file directly under assemblies/ has no
  # folder, so the repo parent is the organization. The repo parent is the
  # deepest folder.
  folder_ids = merge(
    { for path, folder in chainguard_group.folder : path => folder.id },
    module.folder_2.ids,
    module.folder_3.ids,
  )

  repo_parent_id = merge(
    {
      for id, assembly in local.assemblies :
      id => data.chainguard_group.org.id
      if assembly.folder == null
    },
    {
      for id, assembly in local.assemblies :
      id => local.folder_ids[assembly.folder]
      if assembly.folder != null
    },
  )
}

resource "chainguard_image_repo" "assembly" {
  for_each = local.assemblies

  parent_id   = local.repo_parent_id[each.key]
  name        = each.value.repo
  description = each.value.description

  sync_config {
    source = each.value.source
  }

  # Catalog sync fills these in. Tracking them makes every plan noisy.
  lifecycle {
    ignore_changes = [
      active_tags,
      bundles,
      tier,
      readme,
    ]
  }
}

resource "chainguard_image_overlay" "assembly" {
  for_each = {
    for id, assembly in local.assemblies : id => assembly
    if assembly.has_overlay
  }

  # Overlays are organization-scoped. The folder, when there is one, owns
  # the image repo, and the binding below attaches this overlay to that repo.
  parent_id = data.chainguard_group.org.id
  name      = each.value.folder == null ? each.value.repo : "${replace(each.value.folder, "/", "--")}--${each.value.repo}"
  config    = each.value.overlay_json

  depends_on = [terraform_data.assembly_check, terraform_data.assembly_id]
}

resource "chainguard_image_overlay_binding" "assembly" {
  for_each = {
    for id, assembly in local.assemblies : id => assembly
    if assembly.has_overlay
  }

  repo_id    = chainguard_image_repo.assembly[each.key].id
  overlay_id = chainguard_image_overlay.assembly[each.key].id

  tag_selector {
    kind         = each.value.selector_kind
    tags         = each.value.selector_kind == "EXACT" ? each.value.selector_tags : null
    variant_type = each.value.selector_kind == "VARIANT" ? each.value.selector_variant : null
  }
}
