output "organization_id" {
  description = "UIDP of the Chainguard organization."
  value       = data.chainguard_group.org.id
}

output "folders" {
  description = "Chainguard folder name to UIDP."
  value       = { for name, folder in chainguard_group.folder : name => folder.id }
}

output "assemblies" {
  description = "Assembly key to the repo Chainguard syncs. folder is null when the repo is created directly in the organization. overlay_id is null when the file has no Custom Assembly manifest."
  value = {
    for id, assembly in local.assemblies : id => {
      folder     = assembly.folder
      repo       = assembly.repo
      source     = assembly.source
      repo_id    = chainguard_image_repo.assembly[id].id
      overlay_id = try(chainguard_image_overlay.assembly[id].id, null)
      pull       = "cgr.dev/${var.organization}/${assembly.repo}"
    }
  }
}
