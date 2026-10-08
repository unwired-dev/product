#!/usr/bin/env bash
# changesets/action runs this on every push to main without pending changesets.
# Reporting a tag through CHANGESETS_OUTPUT makes the action push it, create its
# GitHub Release from the mobile changelog and set `published`.
set -euo pipefail

mobile=$(node -p "require('./apps/mobile/package.json').version")
macos=$(node -p "require('./apps/macos/package.json').version")
if [[ "$mobile" != "$macos" || ! "$mobile" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo 'The hosts must carry the same numeric release version' >&2
  exit 1
fi
version_pr=$(gh api --paginate "repos/$GITHUB_REPOSITORY/commits/$GITHUB_SHA/pulls" --jq '.[] | select(.merged_at != null and .base.ref == "main" and .head.ref == "changeset-release/main") | .number')
if [[ -z "$version_pr" ]]; then
  echo 'Only a merged version pull request releases the hosts'
  exit 0
fi
tag="v$mobile"
# List through the API so a network/auth error fails rather than looking absent.
existing=$(gh api "repos/$GITHUB_REPOSITORY/git/matching-refs/tags/$tag" --jq ".[] | select(.ref == \"refs/tags/$tag\") | .object.sha")
if [[ -n "$existing" ]]; then
  if [[ "$existing" != "$GITHUB_SHA" ]]; then
    echo 'The release tag points to another commit; refusing to upload it' >&2
    exit 1
  fi
  echo "$tag is already released"
  exit 0
fi
printf '{"type":"git-tag","tag":"%s","packageName":"@private-email/mobile"}\n' "$tag" >> "$CHANGESETS_OUTPUT"
