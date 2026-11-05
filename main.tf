data "chainguard_group" "org" {
  parent_id = "/"
  name      = var.organization
}

resource "chainguard_group" "folder" {
  for_each = local.assembly_folders

  parent_id   = data.chainguard_group.org.id
  name        = each.value
  description = "Custom Assembly images from assemblies/${each.value}."
}

resource "chainguard_image_repo" "assembly" {
  for_each = local.assemblies

  parent_id   = chainguard_group.folder[each.value.folder].id
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
  for_each = local.assemblies

  # Overlays are organization-scoped. The folder owns the image repo, and
  # the binding below attaches this overlay to that repo.
  parent_id = data.chainguard_group.org.id
  name      = "${each.value.folder}--${each.value.repo}"
  config    = each.value.overlay_json

  depends_on = [terraform_data.assembly_check]
}

resource "chainguard_image_overlay_binding" "assembly" {
  for_each = local.assemblies

  repo_id    = chainguard_image_repo.assembly[each.key].id
  overlay_id = chainguard_image_overlay.assembly[each.key].id

  tag_selector {
    kind         = each.value.selector_kind
    tags         = each.value.selector_kind == "EXACT" ? each.value.selector_tags : null
    variant_type = each.value.selector_kind == "VARIANT" ? each.value.selector_variant : null
  }
}
