locals {
  fragment_inputs = {
    for index, raw in var.include_raw_jsons : format("%03d", index) => {
      raw = raw
      label = (
        length(var.include_paths) == length(var.include_raw_jsons) ?
        var.include_paths[index] :
        "include[${index}]"
      )
    }
  }
}

module "image_document" {
  source        = "./document"
  label         = var.filename
  raw_json      = var.raw_json
  allow_include = true
}

module "fragment_document" {
  source        = "./document"
  for_each      = local.fragment_inputs
  label         = each.value.label
  raw_json      = each.value.raw
  allow_include = false
}

locals {
  # Fragments keep include order. The image is applied last.
  documents = concat(
    [for id in sort(keys(module.fragment_document)) : module.fragment_document[id].fields],
    [module.image_document.fields],
  )

  environment = merge([for document in local.documents : document.environment]...)
  annotations = merge([for document in local.documents : document.annotations]...)

  packages             = flatten([for document in local.documents : document.packages])
  runtime_repositories = flatten([for document in local.documents : document.runtime_repositories])
  runtime_keyring      = flatten([for document in local.documents : document.runtime_keyring])
  certificates         = flatten([for document in local.documents : document.certificates])
  users                = flatten([for document in local.documents : document.users])
  groups               = flatten([for document in local.documents : document.groups])
  preflight            = flatten([for document in local.documents : document.preflight])

  run_as_values = [for document in local.documents : document.run_as if document.run_as != null]
  run_as        = length(local.run_as_values) == 0 ? null : local.run_as_values[length(local.run_as_values) - 1]

  fail_mode_values = [for document in local.documents : document.fail_mode if document.fail_mode != null]
  fail_mode        = length(local.fail_mode_values) == 0 ? null : local.fail_mode_values[length(local.fail_mode_values) - 1]

  guarded_values     = [for document in local.documents : document.guarded_entrypoint if document.guarded_entrypoint != null]
  guarded_entrypoint = length(local.guarded_values) == 0 ? null : local.guarded_values[length(local.guarded_values) - 1]

  command_documents = [for document in local.documents : document if document.has_command_override]
  command_document  = length(local.command_documents) == 0 ? null : local.command_documents[length(local.command_documents) - 1]

  trust_documents = [for document in local.documents : document if document.has_truststore]
  trust_document  = length(local.trust_documents) == 0 ? null : local.trust_documents[length(local.trust_documents) - 1]

  any_repo = module.image_document.has_repo || anytrue([for document in module.fragment_document : document.has_repo])

  fragment_errors = [
    for id in sort(keys(module.fragment_document)) : module.fragment_document[id].error
    if !module.fragment_document[id].valid
  ]
  fragments_ok = (
    length(var.include_paths) == length(var.include_raw_jsons) &&
    length(local.fragment_errors) == 0
  )
  fragment_error_message = join(" ", concat(
    length(var.include_paths) == length(var.include_raw_jsons) ? [] : ["include path count does not match fragment documents."],
    local.fragment_errors,
  ))

  has_manifest = (
    length(local.environment) > 0 ||
    length(local.annotations) > 0 ||
    length(local.packages) > 0 ||
    length(local.runtime_repositories) > 0 ||
    length(local.runtime_keyring) > 0 ||
    length(local.certificates) > 0 ||
    length(local.users) > 0 ||
    length(local.groups) > 0 ||
    local.run_as != null ||
    length(local.preflight) > 0 ||
    local.fail_mode != null ||
    local.guarded_entrypoint != null ||
    local.command_document != null ||
    local.trust_document != null
  )

  # chainguard_image_overlay.config is one JSON string. Empty sections are
  # left out so a source-only file sends no manifest.
  object_pairs = compact(concat(
    length(local.environment) == 0 ? [] : ["${jsonencode("environment")}:${jsonencode(local.environment)}"],
    length(local.annotations) == 0 ? [] : ["${jsonencode("annotations")}:${jsonencode(local.annotations)}"],
    local.contents_json == null ? [] : ["${jsonencode("contents")}:${local.contents_json}"],
    local.accounts_json == null ? [] : ["${jsonencode("accounts")}:${local.accounts_json}"],
    local.certificates_json == null ? [] : ["${jsonencode("certificates")}:${local.certificates_json}"],
    length(local.preflight) == 0 ? [] : ["${jsonencode("preflight")}:${local.preflight_json}"],
    local.fail_mode == null ? [] : ["${jsonencode("fail_mode")}:${jsonencode(local.fail_mode)}"],
    local.guarded_entrypoint == null ? [] : ["${jsonencode("guarded_entrypoint")}:${jsonencode(local.guarded_entrypoint)}"],
    local.command_document == null ? [] : ["${jsonencode("command_override")}:${local.command_json}"],
    local.trust_document == null ? [] : ["${jsonencode("truststores")}:${local.truststores_json}"],
  ))
  overlay_json = "{${join(",", local.object_pairs)}}"

  contents_pairs = compact(concat(
    length(local.packages) == 0 ? [] : ["${jsonencode("packages")}:${jsonencode(local.packages)}"],
    length(local.runtime_repositories) == 0 ? [] : ["${jsonencode("runtime_repositories")}:${jsonencode(local.runtime_repositories)}"],
    length(local.runtime_keyring) == 0 ? [] : ["${jsonencode("runtime_keyring")}:${local.keyring_json}"],
  ))
  contents_json = length(local.contents_pairs) == 0 ? null : "{${join(",", local.contents_pairs)}}"
  keyring_json = "[${join(",", [
    for entry in local.runtime_keyring : "{${join(",", compact([
      entry.name == null ? "" : "${jsonencode("name")}:${jsonencode(entry.name)}",
      entry.content == null ? "" : "${jsonencode("content")}:${jsonencode(entry.content)}",
    ]))}}"
  ])}]"

  certificate_json = "[${join(",", [
    for entry in local.certificates : "{${join(",", compact([
      entry.name == null ? "" : "${jsonencode("name")}:${jsonencode(entry.name)}",
      entry.content == null ? "" : "${jsonencode("content")}:${jsonencode(entry.content)}",
    ]))}}"
  ])}]"
  certificates_json = length(local.certificates) == 0 ? null : "{${jsonencode("additional")}:${local.certificate_json}}"

  user_json = "[${join(",", [
    for entry in local.users : "{${join(",", compact([
      entry.username == null ? "" : "${jsonencode("username")}:${jsonencode(entry.username)}",
      entry.uid == null ? "" : "${jsonencode("uid")}:${jsonencode(entry.uid)}",
      entry.gid == null ? "" : "${jsonencode("gid")}:${jsonencode(entry.gid)}",
      entry.homedir == null ? "" : "${jsonencode("homedir")}:${jsonencode(entry.homedir)}",
      entry.shell == null ? "" : "${jsonencode("shell")}:${jsonencode(entry.shell)}",
      entry.groups == null ? "" : "${jsonencode("groups")}:${jsonencode(entry.groups)}",
    ]))}}"
  ])}]"
  group_json = "[${join(",", [
    for entry in local.groups : "{${join(",", compact([
      entry.groupname == null ? "" : "${jsonencode("groupname")}:${jsonencode(entry.groupname)}",
      entry.gid == null ? "" : "${jsonencode("gid")}:${jsonencode(entry.gid)}",
      entry.members == null ? "" : "${jsonencode("members")}:${jsonencode(entry.members)}",
    ]))}}"
  ])}]"
  account_pairs = compact(concat(
    local.run_as == null ? [] : ["${jsonencode("run_as")}:${jsonencode(local.run_as)}"],
    length(local.users) == 0 ? [] : ["${jsonencode("users")}:${local.user_json}"],
    length(local.groups) == 0 ? [] : ["${jsonencode("groups")}:${local.group_json}"],
  ))
  accounts_json = length(local.account_pairs) == 0 ? null : "{${join(",", local.account_pairs)}}"

  preflight_json = "[${join(",", [
    for entry in local.preflight : "{${join(",", compact([
      entry.tcp == null ? "" : "${jsonencode("tcp")}:${jsonencode(entry.tcp)}",
      entry.path == null ? "" : "${jsonencode("path")}:${jsonencode(entry.path)}",
      entry.timeout == null ? "" : "${jsonencode("timeout")}:${jsonencode(entry.timeout)}",
      entry.interval == null ? "" : "${jsonencode("interval")}:${jsonencode(entry.interval)}",
      entry.on_failure == null ? "" : "${jsonencode("on_failure")}:${jsonencode(entry.on_failure)}",
    ]))}}"
  ])}]"

  command_pairs = local.command_document == null ? [] : compact(concat(
    local.command_document.command_mode == null ? [] : ["${jsonencode("mode")}:${jsonencode(local.command_document.command_mode)}"],
    ["${jsonencode("command")}:${jsonencode(local.command_document.command)}"],
  ))
  command_json = "{${join(",", local.command_pairs)}}"

  truststores_json = "[${join(",", [
    for entry in local.trust_document == null ? [] : local.trust_document.truststores : "{${join(",", compact([
      entry.sources == null ? "" : "${jsonencode("sources")}:${jsonencode(entry.sources)}",
      entry.output == null ? "" : "${jsonencode("output")}:${jsonencode(entry.output)}",
      entry.system == null ? "" : "${jsonencode("system")}:${jsonencode(entry.system)}",
      entry.password_env == null ? "" : "${jsonencode("password_env")}:${jsonencode(entry.password_env)}",
      entry.format == null ? "" : "${jsonencode("format")}:${jsonencode(entry.format)}",
    ]))}}"
  ])}]"
}
