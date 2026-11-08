#!/usr/bin/env bash
# Runs the TypeScript and Fallow job commands from .github/workflows/ci.yml
# locally and prints one verdict line to hand to the reviewer. Update this list
# when those jobs change.
# Usage: mise exec -- scripts/pre-handoff.sh [--baseline] [comparison-base]
# The comparison base defaults to the merge-base with origin/main. --baseline
# runs the checks on HEAD in a detached worktree, so edits made meanwhile in
# this checkout cannot change the result.

set -uo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 2
if [ "${1:-}" = --baseline ]; then
  shift
  tmp=$(mktemp -d) || exit 2
  trap 'git worktree remove --force "$tmp/base"; rm -rf "$tmp"' EXIT
  git worktree add --detach --quiet "$tmp/base" HEAD || exit 2
  cd "$tmp/base" && pnpm install --frozen-lockfile --silent && scripts/pre-handoff.sh "$@"
  exit
fi
if ! base=$(git rev-parse --verify --quiet "${1:-$(git merge-base HEAD origin/main)}^{commit}"); then
  printf '\npre-handoff: FAIL: no comparison base (pass one or fetch origin/main)\n'
  exit 1
fi
failed=()

step() {
  printf '\n==> %s\n' "$*"
  "$@" || failed+=("$*")
}

step bash scripts/check-workflow-permissions.sh
step node scripts/check-changesets.mjs
step node --test scripts/check-changesets.test.mjs scripts/release.test.mjs scripts/auto-merge.test.mjs
step pnpm test:native-runner
step pnpm test:tooling
step pnpm exec turbo run lint lint:boundaries format check-types test --continue=dependencies-successful \
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
