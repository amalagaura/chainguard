variable "paths" {
  type        = set(string)
  description = "Folder paths at this depth, such as platform/prod."
}

variable "parent_ids" {
  type        = map(string)
  description = "UIDP of the folder one level above each path, keyed by that parent path."
}

resource "chainguard_group" "folder" {
  for_each = var.paths

  parent_id   = var.parent_ids[dirname(each.value)]
  name        = basename(each.value)
  description = "Custom Assembly images from assemblies/${each.value}."
}

output "ids" {
  value       = { for path, folder in chainguard_group.folder : path => folder.id }
  description = "Folder path to UIDP for this depth."
}
