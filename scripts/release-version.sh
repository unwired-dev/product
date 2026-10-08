#!/usr/bin/env bash
# changesets/action runs this to prepare the version pull request.
set -euo pipefail

# A successful no-op would still let the action force-update the version branch.
main=$(gh api "repos/$GITHUB_REPOSITORY/git/ref/heads/main" --jq '.object.sha')
if [[ "$main" != "$GITHUB_SHA" ]]; then
  echo 'Refusing stale version planning; run the Release workflow for current main' >&2
  exit 1
fi

mobile=$(node -p "require('./apps/mobile/package.json').version")
pnpm version-packages
# Backend-only changesets still produce a release PR. Give the hosts a patch
# when Changesets did not advance them through the fixed group.
if [[ "$(node -p "require('./apps/mobile/package.json').version")" == "$mobile" ]]; then
  printf '%s\n' '---' '"@private-email/mobile": patch' '---' '' 'Release the workspace changes in both TestFlight hosts.' > .changeset/release-hosts.md
  pnpm version-packages
fi
mobile=$(node -p "require('./apps/mobile/package.json').version")
macos=$(node -p "require('./apps/macos/package.json').version")
if [[ "$mobile" != "$macos" || ! "$mobile" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo 'Versioning must leave both hosts on the same numeric release version' >&2
  exit 1
fi
