#!/usr/bin/env bash

set -euo pipefail

repository_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
skill_file="$repository_root/.agents/skills/babysit-pr/SKILL.md"
agents_file="$repository_root/AGENTS.md"
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

require_text "$skill_file" "## Remote validation fallback"
require_text "$skill_file" \
  "Local validation unavailability does not block synchronization,"
require_text "$skill_file" \
  "Never execute PR-controlled code in this trusted mutation checkout."
require_text "$skill_file" \
  "GitHub Actions as the validation evidence for the pushed candidate."
require_text "$skill_file" \
  "validation identity is not itself a blocker."
require_text "$agents_file" \
  "current-head required GitHub Actions without executing PR-controlled code"
require_text "$ci_file" "permissions:"
require_text "$ci_file" "  contents: read"

checkout_count=$(grep -Fc -- "uses: actions/checkout@" "$ci_file")
credential_free_checkout_count=$(grep -Fc -- "persist-credentials: false" "$ci_file")
if [[ $checkout_count -ne $credential_free_checkout_count ]]; then
  printf 'Every actions/checkout step must set persist-credentials: false\n' >&2
  exit 1
fi
