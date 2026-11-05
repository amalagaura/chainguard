#!/bin/sh
# Terraform Enterprise agent hook. The workspace must set
# TFC_WORKLOAD_IDENTITY_AUDIENCE to the audience on the Chainguard
# assumable identity (https://issuer.enforce.dev is the usual value).
# Terraform Enterprise then injects TFC_WORKLOAD_IDENTITY_TOKEN.
#
# Point the agent at this script with TFC_AGENT_HOOK_PRE_PLAN and
# TFC_AGENT_HOOK_PRE_APPLY, or append it to the agent's existing hook.
# The identity UIDP is the assumable identity created once for this workspace.

if [ -z "${TFC_WORKLOAD_IDENTITY_TOKEN:-}" ]; then
  echo "TFC_WORKLOAD_IDENTITY_TOKEN is empty. Set TFC_WORKLOAD_IDENTITY_AUDIENCE on the workspace." >&2
  exit 1
fi

if [ -z "${CHAINGUARD_IDENTITY_ID:-}" ]; then
  echo "CHAINGUARD_IDENTITY_ID is empty. Set it to the assumable identity UIDP." >&2
  exit 1
fi

export TF_CHAINGUARD_IDENTITY_TOKEN="$TFC_WORKLOAD_IDENTITY_TOKEN"
export TF_CHAINGUARD_IDENTITY="$CHAINGUARD_IDENTITY_ID"
