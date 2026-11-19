variable "label" {
  type        = string
  description = "File name used in plan errors."
}

variable "raw_json" {
  type        = string
  description = "JSON encoding of one YAML document."
}

variable "allow_include" {
  type        = bool
  description = "The image file may list include. A fragment may not."
}

locals {
  doc                = jsondecode(var.raw_json)
  is_mapping         = can(keys(local.doc))
  has_overlay        = local.is_mapping ? contains(keys(local.doc), "overlay") : false
  overlay_is_mapping = local.has_overlay ? can(keys(local.doc.overlay)) : true
  has_include        = local.is_mapping ? contains(keys(local.doc), "include") : false
  usable             = local.is_mapping && local.overlay_is_mapping && (var.allow_include || !local.has_include)

  # A conditional cannot return both the shorthand document and its overlay,
  # because those objects have different attributes. Encode the chosen body
  # so the field reads below see one value.
  body_json = (
    !local.usable ? "{}" :
    local.has_overlay ? jsonencode(local.doc.overlay) :
    jsonencode(local.doc)
  )
  source      = jsondecode(local.body_json)
  source_keys = toset(try(keys(local.source), []))

  metadata_keys = toset(["source", "description", "tags", "include", "repo", "overlay"])
  manifest_keys = toset([
    "contents",
    "environment",
    "annotations",
    "accounts",
    "certificates",
    "guarded_entrypoint",
    "command_override",
    "preflight",
    "fail_mode",
    "truststore",
    "truststores",
  ])

  unknown_top = [
    for key in local.source_keys : key
    if !contains(local.manifest_keys, key) && !contains(local.metadata_keys, key)
  ]

  has_contents       = contains(local.source_keys, "contents")
  contents_is_object = local.has_contents ? can(keys(local.source.contents)) : true
  content_keys       = local.contents_is_object && local.has_contents ? toset(keys(local.source.contents)) : toset([])
  content_known      = toset(["packages", "runtime_repositories", "runtime_keyring"])
  unknown_contents = [
    for key in local.content_keys : "contents.${key}"
    if !contains(local.content_known, key)
  ]

  environment_is_map = contains(local.source_keys, "environment") ? can(keys(try(local.source.environment, {}))) : true
  environment_values_are_strings = local.environment_is_map ? alltrue([
    for value in values(try(local.source.environment, {})) : can(tostring(value))
  ]) : true
  environment = (
    local.environment_is_map && local.environment_values_are_strings ?
    { for key, value in try(local.source.environment, {}) : key => tostring(value) } :
    {}
  )

  annotations_is_map = contains(local.source_keys, "annotations") ? can(keys(try(local.source.annotations, {}))) : true
  annotations_values_are_strings = local.annotations_is_map ? alltrue([
    for value in values(try(local.source.annotations, {})) : can(tostring(value))
  ]) : true
  annotations = (
    local.annotations_is_map && local.annotations_values_are_strings ?
    { for key, value in try(local.source.annotations, {}) : key => tostring(value) } :
    {}
  )

  packages_are_list = contains(local.content_keys, "packages") ? can([for item in local.source.contents.packages : item]) : true
  packages = (
    local.packages_are_list ?
    [for item in try(local.source.contents.packages, []) : tostring(item)] :
    []
  )

  repositories_are_list = contains(local.content_keys, "runtime_repositories") ? can([for item in local.source.contents.runtime_repositories : item]) : true
  runtime_repositories = (
    local.repositories_are_list ?
    [for item in try(local.source.contents.runtime_repositories, []) : tostring(item)] :
    []
  )

  keyring_known    = toset(["name", "content"])
  keyring_are_list = contains(local.content_keys, "runtime_keyring") ? can([for item in local.source.contents.runtime_keyring : item]) : true
  keyring_items    = local.keyring_are_list ? try(local.source.contents.runtime_keyring, []) : []
  unknown_keyring = distinct(flatten([
    for item in local.keyring_items : [
      for key in(can(keys(item)) ? keys(item) : []) : "contents.runtime_keyring.${key}"
      if !contains(local.keyring_known, key)
    ]
  ]))
  runtime_keyring = [
    for item in local.keyring_items : {
      name    = can(keys(item)) && contains(keys(item), "name") ? tostring(item.name) : null
      content = can(keys(item)) && contains(keys(item), "content") ? tostring(item.content) : null
    }
  ]

  accounts_is_object = contains(local.source_keys, "accounts") ? can(keys(local.source.accounts)) : true
  account_keys       = local.accounts_is_object && contains(local.source_keys, "accounts") ? toset(keys(local.source.accounts)) : toset([])
  account_known      = toset(["users", "groups", "run_as", "run-as"])
  unknown_accounts = [
    for key in local.account_keys : "accounts.${key}"
    if !contains(local.account_known, key)
  ]

  user_known     = toset(["username", "uid", "gid", "homedir", "shell", "groups"])
  users_are_list = contains(local.account_keys, "users") ? can([for item in local.source.accounts.users : item]) : true
  user_items     = local.users_are_list ? try(local.source.accounts.users, []) : []
  unknown_users = distinct(flatten([
    for item in local.user_items : [
      for key in(can(keys(item)) ? keys(item) : []) : "accounts.users.${key}"
      if !contains(local.user_known, key)
    ]
  ]))
  users = [
    for item in local.user_items : {
      username = can(keys(item)) && contains(keys(item), "username") ? tostring(item.username) : null
      uid      = can(keys(item)) && contains(keys(item), "uid") ? tonumber(item.uid) : null
      gid      = can(keys(item)) && contains(keys(item), "gid") ? tonumber(item.gid) : null
      homedir  = can(keys(item)) && contains(keys(item), "homedir") ? tostring(item.homedir) : null
      shell    = can(keys(item)) && contains(keys(item), "shell") ? tostring(item.shell) : null
      groups = (
        can(keys(item)) && contains(keys(item), "groups") ?
        [for group in item.groups : tostring(group)] :
        null
      )
    }
  ]

  group_known     = toset(["groupname", "gid", "members"])
  groups_are_list = contains(local.account_keys, "groups") ? can([for item in local.source.accounts.groups : item]) : true
  group_items     = local.groups_are_list ? try(local.source.accounts.groups, []) : []
  unknown_groups = distinct(flatten([
    for item in local.group_items : [
      for key in(can(keys(item)) ? keys(item) : []) : "accounts.groups.${key}"
      if !contains(local.group_known, key)
    ]
  ]))
  groups = [
    for item in local.group_items : {
      groupname = can(keys(item)) && contains(keys(item), "groupname") ? tostring(item.groupname) : null
      gid       = can(keys(item)) && contains(keys(item), "gid") ? tonumber(item.gid) : null
      members = (
        can(keys(item)) && contains(keys(item), "members") ?
        [for member in item.members : tostring(member)] :
        null
      )
    }
  ]

  has_run_as     = contains(local.account_keys, "run_as")
  has_run_hyphen = contains(local.account_keys, "run-as")
  run_as = (
    local.has_run_as ? tostring(local.source.accounts.run_as) :
    local.has_run_hyphen ? tostring(local.source.accounts["run-as"]) :
    null
  )

  certificates_is_object = contains(local.source_keys, "certificates") ? can(keys(local.source.certificates)) : true
  certificate_keys       = local.certificates_is_object && contains(local.source_keys, "certificates") ? toset(keys(local.source.certificates)) : toset([])
  unknown_certificates = [
    for key in local.certificate_keys : "certificates.${key}"
    if key != "additional"
  ]
  certificate_known     = toset(["name", "content"])
  certificates_are_list = contains(local.certificate_keys, "additional") ? can([for item in local.source.certificates.additional : item]) : true
  certificate_items     = local.certificates_are_list ? try(local.source.certificates.additional, []) : []
  unknown_certificate_entries = distinct(flatten([
    for item in local.certificate_items : [
      for key in(can(keys(item)) ? keys(item) : []) : "certificates.additional.${key}"
      if !contains(local.certificate_known, key)
    ]
  ]))
  certificates = [
    for item in local.certificate_items : {
      name    = can(keys(item)) && contains(keys(item), "name") ? tostring(item.name) : null
      content = can(keys(item)) && contains(keys(item), "content") ? tostring(item.content) : null
    }
  ]

  preflight_known   = toset(["tcp", "path", "timeout", "interval", "on_failure"])
  preflight_is_list = contains(local.source_keys, "preflight") ? can([for item in local.source.preflight : item]) : true
  preflight_items   = local.preflight_is_list ? try(local.source.preflight, []) : []
  unknown_preflight = distinct(flatten([
    for item in local.preflight_items : [
      for key in(can(keys(item)) ? keys(item) : []) : "preflight.${key}"
      if !contains(local.preflight_known, key)
    ]
  ]))
  preflight = [
    for item in local.preflight_items : {
      tcp        = can(keys(item)) && contains(keys(item), "tcp") ? tostring(item.tcp) : null
      path       = can(keys(item)) && contains(keys(item), "path") ? tostring(item.path) : null
      timeout    = can(keys(item)) && contains(keys(item), "timeout") ? tostring(item.timeout) : null
      interval   = can(keys(item)) && contains(keys(item), "interval") ? tostring(item.interval) : null
      on_failure = can(keys(item)) && contains(keys(item), "on_failure") ? tostring(item.on_failure) : null
    }
  ]

  has_fail_mode = contains(local.source_keys, "fail_mode")
  fail_mode     = local.has_fail_mode ? tostring(local.source.fail_mode) : null

  has_guarded_entrypoint = contains(local.source_keys, "guarded_entrypoint")
  guarded_entrypoint     = local.has_guarded_entrypoint ? tobool(local.source.guarded_entrypoint) : null

  command_known              = toset(["mode", "command"])
  has_command_override       = contains(local.source_keys, "command_override")
  command_override_is_object = local.has_command_override ? can(keys(local.source.command_override)) : true
  command_keys               = local.command_override_is_object && local.has_command_override ? toset(keys(local.source.command_override)) : toset([])
  unknown_command = [
    for key in local.command_keys : "command_override.${key}"
    if !contains(local.command_known, key)
  ]
  command_is_list = contains(local.command_keys, "command") ? can([for item in local.source.command_override.command : item]) : true
  command_mode    = contains(local.command_keys, "mode") ? tostring(local.source.command_override.mode) : null
  command = (
    local.command_is_list ?
    [for item in try(local.source.command_override.command, []) : tostring(item)] :
    []
  )

  trust_known         = toset(["sources", "output", "system", "password_env", "format"])
  has_truststores_key = contains(local.source_keys, "truststores")
  has_truststore_key  = contains(local.source_keys, "truststore")
  has_truststore      = local.has_truststores_key || local.has_truststore_key
  raw_trust = (
    local.has_truststores_key ? local.source.truststores :
    local.has_truststore_key ? local.source.truststore :
    null
  )
  trust_is_object = local.raw_trust == null ? false : can(keys(local.raw_trust))
  trust_is_list   = local.raw_trust == null ? false : can([for item in local.raw_trust : item]) && !local.trust_is_object
  trust_items = (
    local.trust_is_object ? [local.raw_trust] :
    local.trust_is_list ? local.raw_trust :
    []
  )
  unknown_trust = distinct(flatten([
    for item in local.trust_items : [
      for key in(can(keys(item)) ? keys(item) : []) : "truststores.${key}"
      if !contains(local.trust_known, key)
    ]
  ]))
  truststores = [
    for item in local.trust_items : {
      sources      = can(keys(item)) && contains(keys(item), "sources") ? [for source in item.sources : tostring(source)] : null
      output       = can(keys(item)) && contains(keys(item), "output") ? tostring(item.output) : null
      system       = can(keys(item)) && contains(keys(item), "system") ? tobool(item.system) : null
      password_env = can(keys(item)) && contains(keys(item), "password_env") ? tostring(item.password_env) : null
      format       = can(keys(item)) && contains(keys(item), "format") ? tostring(item.format) : null
    }
  ]

  has_repo = (
    local.is_mapping ? (
      contains(keys(local.doc), "repo") ? true :
      local.has_overlay && local.overlay_is_mapping ? contains(keys(local.doc.overlay), "repo") :
      false
    ) : false
  )

  unknown_keys = concat(
    local.unknown_top,
    local.contents_is_object ? local.unknown_contents : [],
    local.unknown_keyring,
    local.accounts_is_object ? local.unknown_accounts : [],
    local.unknown_users,
    local.unknown_groups,
    local.certificates_is_object ? local.unknown_certificates : [],
    local.unknown_certificate_entries,
    local.unknown_preflight,
    local.command_override_is_object ? local.unknown_command : [],
    local.unknown_trust,
  )

  errors = compact([
    local.is_mapping ? "" : "${var.label} must be a YAML mapping.",
    local.overlay_is_mapping ? "" : "${var.label} overlay must be a mapping.",
    var.allow_include || !local.has_include ? "" : "${var.label} cannot contain include. List shared files from the image definition.",
    length(local.unknown_keys) == 0 ? "" : "${var.label} has unknown manifest keys: ${join(", ", local.unknown_keys)}.",
    local.contents_is_object ? "" : "${var.label} contents must be an object.",
    local.environment_is_map && local.environment_values_are_strings ? "" : "${var.label} environment must be a map of strings.",
    local.annotations_is_map && local.annotations_values_are_strings ? "" : "${var.label} annotations must be a map of strings.",
    local.packages_are_list ? "" : "${var.label} contents.packages must be a list.",
    local.repositories_are_list ? "" : "${var.label} contents.runtime_repositories must be a list.",
    local.keyring_are_list ? "" : "${var.label} contents.runtime_keyring must be a list.",
    local.accounts_is_object ? "" : "${var.label} accounts must be an object.",
    local.users_are_list ? "" : "${var.label} accounts.users must be a list.",
    local.groups_are_list ? "" : "${var.label} accounts.groups must be a list.",
    local.certificates_is_object ? "" : "${var.label} certificates must be an object.",
    local.certificates_are_list ? "" : "${var.label} certificates.additional must be a list.",
    local.preflight_is_list ? "" : "${var.label} preflight must be a list.",
    local.command_override_is_object ? "" : "${var.label} command_override must be an object.",
    local.command_is_list ? "" : "${var.label} command_override.command must be a list.",
    local.raw_trust == null || local.trust_is_object || local.trust_is_list ? "" : "${var.label} truststore must be an object or a list.",
  ])
}

output "valid" {
  value = length(local.errors) == 0
}

output "error" {
  value = join(" ", local.errors)
}

output "has_repo" {
  value = local.has_repo
}

output "fields" {
  value = {
    environment          = local.environment
    annotations          = local.annotations
    packages             = local.packages
    runtime_repositories = local.runtime_repositories
    runtime_keyring      = local.runtime_keyring
    certificates         = local.certificates
    users                = local.users
    groups               = local.groups
    run_as               = local.run_as
    preflight            = local.preflight
    fail_mode            = local.fail_mode
    guarded_entrypoint   = local.guarded_entrypoint
    has_command_override = local.has_command_override && local.command_override_is_object
    command_mode         = local.command_mode
    command              = local.command
    has_truststore       = local.has_truststore && (local.trust_is_object || local.trust_is_list)
    truststores          = local.truststores
  }
}
