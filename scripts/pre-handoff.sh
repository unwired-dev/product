#!/usr/bin/env bash
# Runs the TypeScript and Fallow job commands from .github/workflows/ci.yml
# locally and prints one verdict line for the reviewer handoff. Update this list
# when those jobs change.
# Usage: mise exec -- scripts/pre-handoff.sh [comparison-base]
# The comparison base defaults to the merge-base with origin/main.

set -uo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 2
if ! base=$(git rev-parse --verify --quiet "${1:-$(git merge-base HEAD origin/main)}^{commit}"); then
  printf '\npre-handoff: FAIL: no comparison base (pass one or fetch origin/main)\n'
  exit 1
fi
failed=()

step() {
  printf '\n==> %s\n' "$*"
  "$@" || failed+=("$*")
}

step bash scripts/check-pr-babysitter-contract.sh
step node scripts/check-changesets.mjs
step node --test scripts/check-changesets.test.mjs scripts/release.test.mjs scripts/auto-merge.test.mjs
step pnpm test:native-runner
step pnpm test:tooling
step pnpm exec turbo run lint lint:boundaries format check-types test \
  --filter=// \
  --filter=@private-email/mobile... \
  --filter=@private-email/macos... \
  --filter=@private-email/convex...
step pnpm exec fallow audit --gate new-only --changed-since "$base" --format json --quiet

head=$(git rev-parse --short HEAD)
[ -z "$(git status --porcelain)" ] || head="$head+uncommitted"
if [ ${#failed[@]} -eq 0 ]; then
  printf '\npre-handoff: PASS at %s (base %s)\n' "$head" "$(git rev-parse --short "$base")"
else
  printf '\npre-handoff: FAIL at %s (base %s): %s\n' "$head" "$(git rev-parse --short "$base")" \
    "$(IFS=';'; printf '%s' "${failed[*]}")"
  exit 1
fi
