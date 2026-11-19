run "include_merges_maps_and_appends_lists" {
  command = plan

  module {
    source = "./modules/assembly"
  }

  variables {
    filename = "custom/app.yaml"
    raw_json = jsonencode({
      source  = "wolfi-base"
      include = ["assembly_fragments/certificates.yaml"]
      environment = {
        SHARED = "image"
        OWNER  = "platform"
      }
      contents = {
        packages = ["curl"]
      }
      certificates = {
        additional = [
          { name = "image-ca", content = "pem-b" },
        ]
      }
      annotations = {
        "com.example/team" = "image"
      }
    })
    include_paths = ["assembly_fragments/certificates.yaml"]
    include_raw_jsons = [
      jsonencode({
        source      = "ignored"
        description = "not a repo"
        environment = {
          SHARED = "fragment"
          EXTRA  = "kept"
        }
        contents = {
          packages = ["jq"]
        }
        certificates = {
          additional = [
            { name = "internal-ca", content = "pem-a" },
          ]
        }
        annotations = {
          "com.example/team" = "fragment"
          "com.example/from" = "fragment"
        }
      }),
    ]
  }

  assert {
    condition     = jsondecode(output.overlay_json).environment.SHARED == "image"
    error_message = "The image environment value replaces the fragment value."
  }

  assert {
    condition     = jsondecode(output.overlay_json).environment.EXTRA == "kept"
    error_message = "A fragment environment key stays when the image does not set it."
  }

  assert {
    condition     = jsondecode(output.overlay_json).contents.packages[0] == "jq" && jsondecode(output.overlay_json).contents.packages[1] == "curl"
    error_message = "Package lists append, with the fragment before the image."
  }

  assert {
    condition     = jsondecode(output.overlay_json).certificates.additional[0].name == "internal-ca" && jsondecode(output.overlay_json).certificates.additional[1].name == "image-ca"
    error_message = "Certificate lists append, with the fragment before the image."
  }

  assert {
    condition     = jsondecode(output.overlay_json).annotations["com.example/team"] == "image" && jsondecode(output.overlay_json).annotations["com.example/from"] == "fragment"
    error_message = "Annotation maps merge, and the image wins on a shared key."
  }

  assert {
    condition     = !contains(keys(jsondecode(output.overlay_json)), "include") && !contains(keys(jsondecode(output.overlay_json)), "source") && !contains(keys(jsondecode(output.overlay_json)), "description")
    error_message = "include and fragment metadata are removed before the manifest is sent."
  }

  assert {
    condition     = output.has_overlay
    error_message = "A fragment that adds manifest fields creates an overlay."
  }
}

run "include_rewrites_accounts_after_merge" {
  command = plan

  module {
    source = "./modules/assembly"
  }

  variables {
    filename = "custom/app.yaml"
    raw_json = jsonencode({
      include = ["assembly_fragments/accounts.yaml"]
      contents = {
        packages = ["curl"]
      }
      accounts = {
        run_as = "1000"
        users = [
          { username = "image", uid = 1001 },
        ]
      }
    })
    include_paths = ["assembly_fragments/accounts.yaml"]
    include_raw_jsons = [
      jsonencode({
        accounts = {
          "run-as" = "65532"
          users = [
            { username = "app", uid = 1000 },
          ]
        }
        truststore = {
          sources = ["/etc/service-ca"]
          output  = "/truststore/cacerts"
        }
      }),
    ]
  }

  assert {
    condition     = jsondecode(output.overlay_json).accounts.run_as == "1000" && jsondecode(output.overlay_json).accounts.users[0].username == "app" && jsondecode(output.overlay_json).accounts.users[1].username == "image"
    error_message = "accounts.run-as is rewritten to accounts.run_as, the image replaces it, and user lists append."
  }

  assert {
    condition     = jsondecode(output.overlay_json).truststores[0].output == "/truststore/cacerts" && jsondecode(output.overlay_json).truststores[0].sources[0] == "/etc/service-ca"
    error_message = "A singular truststore object is sent as a one-element truststores list."
  }
}

run "no_include_keeps_the_image_manifest" {
  command = plan

  module {
    source = "./modules/assembly"
  }

  variables {
    filename = "wolfi-base.yaml"
    raw_json = jsonencode({
      source = "wolfi-base"
      contents = {
        packages = ["curl"]
      }
    })
    include_paths     = []
    include_raw_jsons = []
  }

  assert {
    condition     = jsondecode(output.overlay_json).contents.packages[0] == "curl"
    error_message = "A file with no include still sends its own manifest."
  }

  assert {
    condition     = output.source == "wolfi-base" && output.repo == "wolfi-base"
    error_message = "source and the repo name still come from the image file."
  }
}

run "repo_key_in_fragment_is_rejected" {
  command = plan

  module {
    source = "./modules/assembly"
  }

  variables {
    filename = "custom/app.yaml"
    raw_json = jsonencode({
      contents = {
        packages = ["curl"]
      }
    })
    include_paths = ["assembly_fragments/bad.yaml"]
    include_raw_jsons = [
      jsonencode({
        repo = "other-name"
      }),
    ]
  }

  expect_failures = [
    terraform_data.repo_name,
  ]
}

run "source_only_has_no_overlay" {
  command = plan

  module {
    source = "./modules/assembly"
  }

  variables {
    filename = "wolfi-base.yaml"
    raw_json = jsonencode({
      source = "wolfi-base"
    })
  }

  assert {
    condition     = output.has_overlay == false && output.overlay_json == "{}"
    error_message = "A source-only file syncs the catalog image and sends no manifest."
  }

  assert {
    condition     = output.description == "Sync of wolfi-base." && output.source == "wolfi-base"
    error_message = "A source-only file describes itself as a sync of its catalog image."
  }
}

run "two_fragments_apply_in_order" {
  command = plan

  module {
    source = "./modules/assembly"
  }

  variables {
    filename = "custom/app.yaml"
    raw_json = jsonencode({
      source  = "wolfi-base"
      include = ["assembly_fragments/base.yaml", "assembly_fragments/certificates.yaml"]
      environment = {
        SHARED = "image"
      }
      contents = {
        packages = ["curl"]
      }
    })
    include_paths = ["assembly_fragments/base.yaml", "assembly_fragments/certificates.yaml"]
    include_raw_jsons = [
      jsonencode({
        environment = {
          SHARED    = "base"
          FROM_BASE = "yes"
        }
        contents = {
          packages = ["jq", "curl"]
        }
      }),
      jsonencode({
        source = "wrong"
        tags   = { kind = "all" }
        environment = {
          SHARED = "certs"
        }
        certificates = {
          additional = [
            { name = "internal-ca", content = "pem" },
          ]
        }
        contents = {
          packages = ["ca-certificates"]
        }
      }),
    ]
  }

  assert {
    condition     = jsondecode(output.overlay_json).environment.SHARED == "image" && jsondecode(output.overlay_json).environment.FROM_BASE == "yes"
    error_message = "Fragments apply in order, and the image wins on a shared key."
  }

  assert {
    condition     = jsondecode(output.overlay_json).contents.packages[0] == "jq" && jsondecode(output.overlay_json).contents.packages[1] == "curl" && jsondecode(output.overlay_json).contents.packages[2] == "ca-certificates" && jsondecode(output.overlay_json).contents.packages[3] == "curl"
    error_message = "Package lists append in fragment order, including repeated names."
  }

  assert {
    condition     = jsondecode(output.overlay_json).certificates.additional[0].name == "internal-ca" && !contains(keys(jsondecode(output.overlay_json)), "tags") && !contains(keys(jsondecode(output.overlay_json)), "source")
    error_message = "The second fragment contributes its manifest, and its metadata is removed."
  }
}

run "later_file_replaces_single_values" {
  command = plan

  module {
    source = "./modules/assembly"
  }

  variables {
    filename = "custom/app.yaml"
    raw_json = jsonencode({
      fail_mode          = "closed"
      guarded_entrypoint = false
      command_override = {
        mode    = "override"
        command = ["python", "/app/main.py"]
      }
      truststore = {
        sources = ["/etc/corp-ca"]
        output  = "/truststore/corp"
      }
    })
    include_paths = ["assembly_fragments/base.yaml"]
    include_raw_jsons = [
      jsonencode({
        fail_mode          = "open"
        guarded_entrypoint = true
        command_override = {
          mode    = "prepend"
          command = ["wrapper"]
        }
        truststore = {
          sources = ["/etc/service-ca"]
          output  = "/truststore/cacerts"
        }
        preflight = [
          { tcp = "db.internal:5432", timeout = "60s", on_failure = "fail" },
        ]
      }),
    ]
  }

  assert {
    condition     = jsondecode(output.overlay_json).fail_mode == "closed" && jsondecode(output.overlay_json).guarded_entrypoint == false
    error_message = "The image replaces fail_mode and guarded_entrypoint."
  }

  assert {
    condition     = jsondecode(output.overlay_json).command_override.mode == "override" && jsondecode(output.overlay_json).command_override.command[0] == "python" && length(jsondecode(output.overlay_json).command_override.command) == 2
    error_message = "The image replaces command_override as a whole."
  }

  assert {
    condition     = length(jsondecode(output.overlay_json).truststores) == 1 && jsondecode(output.overlay_json).truststores[0].output == "/truststore/corp"
    error_message = "The image replaces truststore, and the result is one truststores entry."
  }

  assert {
    condition     = jsondecode(output.overlay_json).preflight[0].tcp == "db.internal:5432"
    error_message = "A preflight list from the fragment is kept when the image does not set one."
  }
}

run "overlay_wrapper_is_the_manifest_body" {
  command = plan

  module {
    source = "./modules/assembly"
  }

  variables {
    filename = "custom/app.yaml"
    raw_json = jsonencode({
      source      = "busybox"
      description = "tools"
      tags        = { kind = "exact", names = ["latest"] }
      include     = ["assembly_fragments/certificates.yaml"]
      overlay = {
        contents = {
          packages = ["curl"]
        }
      }
    })
    include_paths = ["assembly_fragments/certificates.yaml"]
    include_raw_jsons = [
      jsonencode({
        overlay = {
          certificates = {
            additional = [
              { name = "internal-ca", content = "pem" },
            ]
          }
        }
      }),
    ]
  }

  assert {
    condition     = jsondecode(output.overlay_json).contents.packages[0] == "curl" && jsondecode(output.overlay_json).certificates.additional[0].name == "internal-ca"
    error_message = "The overlay mapping is the manifest body, and the fragment overlay is merged into it."
  }

  assert {
    condition     = !contains(keys(jsondecode(output.overlay_json)), "overlay") && !contains(keys(jsondecode(output.overlay_json)), "description") && !contains(keys(jsondecode(output.overlay_json)), "tags") && output.selector_kind == "EXACT"
    error_message = "Image metadata stays out of the manifest and still selects tags."
  }
}

run "fragment_include_is_rejected" {
  command = plan

  module {
    source = "./modules/assembly"
  }

  variables {
    filename = "custom/app.yaml"
    raw_json = jsonencode({
      contents = {
        packages = ["curl"]
      }
    })
    include_paths = ["assembly_fragments/base.yaml"]
    include_raw_jsons = [
      jsonencode({
        include = ["other.yaml"]
        environment = {
          SHARED = "fragment"
        }
      }),
    ]
  }

  expect_failures = [
    terraform_data.fragments[0],
  ]
}

run "fragment_must_be_a_mapping" {
  command = plan

  module {
    source = "./modules/assembly"
  }

  variables {
    filename = "custom/app.yaml"
    raw_json = jsonencode({
      contents = {
        packages = ["curl"]
      }
    })
    include_paths = ["assembly_fragments/packages.yaml"]
    include_raw_jsons = [
      jsonencode(["curl"]),
    ]
  }

  expect_failures = [
    terraform_data.fragments[0],
  ]
}

run "fragment_overlay_must_be_a_mapping" {
  command = plan

  module {
    source = "./modules/assembly"
  }

  variables {
    filename = "custom/app.yaml"
    raw_json = jsonencode({
      contents = {
        packages = ["curl"]
      }
    })
    include_paths = ["assembly_fragments/bad.yaml"]
    include_raw_jsons = [
      jsonencode({
        overlay = ["curl"]
      }),
    ]
  }

  expect_failures = [
    terraform_data.fragments[0],
  ]
}

run "include_path_count_must_match" {
  command = plan

  module {
    source = "./modules/assembly"
  }

  variables {
    filename          = "custom/app.yaml"
    raw_json          = jsonencode({ source = "wolfi-base" })
    include_paths     = ["assembly_fragments/certificates.yaml"]
    include_raw_jsons = []
  }

  expect_failures = [
    terraform_data.fragments[0],
  ]
}

run "unknown_manifest_key_is_rejected" {
  command = plan

  module {
    source = "./modules/assembly"
  }

  variables {
    filename = "custom/app.yaml"
    raw_json = jsonencode({
      contents = {
        packages = ["curl"]
      }
    })
    include_paths = ["assembly_fragments/bad.yaml"]
    include_raw_jsons = [
      jsonencode({
        certificates = {
          providers = ["aws"]
        }
      }),
    ]
  }

  expect_failures = [
    terraform_data.fragments[0],
  ]
}

run "image_must_be_a_mapping" {
  command = plan

  module {
    source = "./modules/assembly"
  }

  variables {
    filename = "custom/app.yaml"
    raw_json = jsonencode(["curl"])
  }

  expect_failures = [
    terraform_data.repo_name,
  ]
}
