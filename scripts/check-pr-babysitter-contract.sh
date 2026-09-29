#!/usr/bin/env bash

set -euo pipefail

repository_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
agents_file="$repository_root/AGENTS.md"
policy_file="$repository_root/docs/agents/pull-request-babysitting.md"
testing_policy_file="$repository_root/docs/agents/testing.md"
ci_file="$repository_root/.github/workflows/ci.yml"

require_text() {
  local file=$1
  local text=$2

  if ! grep -Fq -- "$text" "$file"; then
    printf 'Missing PR babysitter contract in %s: %s\n' \
      "${file#"$repository_root/"}" "$text" >&2
    return 1
  fi
}

require_text "$agents_file" \
  "[repository policy](docs/agents/pull-request-babysitting.md)"
require_text "$policy_file" \
  "repairs valid feedback and every current required GitHub Actions failure."
require_text "$policy_file" \
  "Inspect each failing leaf job's logs and make the smallest safe fix, including"
require_text "$policy_file" \
  "failures already present on the base branch. Attribution determines the"
require_text "$policy_file" \
  "explanation and repair scope, not whether to repair the failure."
require_text "$policy_file" \
  "repair, or a missing or stale status reply, make no changes and report no action."
require_text "$policy_file" \
  "The task uses the GitHub authentication and Git author configured for the agent."
require_text "$policy_file" \
  "bot account or optional wrapper is not."
require_text "$policy_file" \
  "For a named PR request, process only that PR."
require_text "$policy_file" \
  "trusted-base local validation as the existing agent local OS account only"
require_text "$policy_file" \
  "inside Codex's \`workspace-write\` sandbox, after harmless probes confirm that"
require_text "$policy_file" \
  "or paths outside its run workspace. It never requests host escalation or runs"
require_text "$policy_file" "PR-controlled code outside that sandbox."
require_text "$policy_file" \
  "sanitized, hook-free checkout, pushes the candidate, and uses current-head"
require_text "$policy_file" \
  "required GitHub Actions as the isolated validation evidence. An unavailable"
require_text "$policy_file" \
  "compatible local sandbox route alone does not stop synchronization, review"
require_text "$policy_file" "fixes, or required CI repair."
require_text "$testing_policy_file" \
  "This exception never applies to the PR babysitter workflow,"
require_text "$testing_policy_file" "including trusted-base validation."
require_text "$ci_file" "permissions:"
require_text "$ci_file" "  contents: read"

checkout_count=$(grep -Fc -- "uses: actions/checkout@" "$ci_file")
credential_free_checkout_count=$(grep -Fc -- "persist-credentials: false" "$ci_file")
if [[ $checkout_count -ne $credential_free_checkout_count ]]; then
  printf 'Every actions/checkout step must set persist-credentials: false\n' >&2
  exit 1
fi
