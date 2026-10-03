#!/usr/bin/env bash
set -euo pipefail

echo 'release=false' >> "$GITHUB_OUTPUT"
gh auth setup-git
node scripts/check-changesets.mjs

mobile=$(node -p "require('./apps/mobile/package.json').version")
macos=$(node -p "require('./apps/macos/package.json').version")
if [[ "$mobile" != "$macos" || ! "$mobile" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo 'The hosts must carry the same numeric release version' >&2
  exit 1
fi

pending=$(find .changeset -maxdepth 1 -name '*.md' ! -name README.md | wc -l)
if (( pending > 0 )); then
  # An old rerun must not replace a PR prepared from newer main.
  main=$(git ls-remote origin refs/heads/main | cut -f1)
  if [[ "$main" != "$GITHUB_SHA" ]]; then
    echo 'Newer main will prepare the version pull request'
    exit 0
  fi
  branch=changeset-release/main
  previous=$(git ls-remote origin "refs/heads/$branch" | cut -f1)
  if [[ -n "$previous" ]]; then
    git fetch origin "refs/heads/$branch"
  fi
  pnpm version-packages
  # A backend-only or empty changeset still produces a release PR. Give the
  # hosts a patch when Changesets did not advance them through the fixed group.
  next_mobile=$(node -p "require('./apps/mobile/package.json').version")
  if [[ "$next_mobile" == "$mobile" ]]; then
    printf '%s\n' '---' '"@private-email/mobile": patch' '---' '' 'Release the workspace changes in both TestFlight hosts.' > .changeset/release-hosts.md
    pnpm version-packages
  fi
  mobile=$(node -p "require('./apps/mobile/package.json').version")
  macos=$(node -p "require('./apps/macos/package.json').version")
  if [[ "$mobile" != "$macos" || ! "$mobile" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo 'Versioning must leave both hosts on the same numeric release version' >&2
    exit 1
  fi
  git add .changeset apps packages pnpm-lock.yaml
  # Preserve the existing commit and its CI results on an unchanged rerun.
  if [[ -z "$previous" || "$(git write-tree)" != "$(git rev-parse "$previous^{tree}")" ]]; then
    git config user.name 'github-actions[bot]'
    git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
    git checkout -B "$branch"
    git commit -m 'Version packages'
    git push --force-with-lease="refs/heads/$branch:$previous" origin "HEAD:refs/heads/$branch"
  fi
  body="$RUNNER_TEMP/version-packages-body.md"
  printf 'Merging this pull request tags v%s, creates its GitHub Release and uploads both hosts to TestFlight.\n' "$mobile" > "$body"
  pr=$(gh pr list --base main --head "$branch" --state open --json number --jq '.[0].number // empty')
  if [[ -n "$pr" ]]; then
    # REST updates need only pull-request write, without optional Projects access.
    gh api --method PATCH "repos/$GITHUB_REPOSITORY/pulls/$pr" -f "title=Version packages: v$mobile" -F "body=@$body" > /dev/null
  else
    gh pr create --base main --head "$branch" --title "Version packages: v$mobile" --body-file "$body"
  fi
  exit 0
fi

# An ordinary docs/test push with no changesets is not a release decision.
previous_version=$(git show 'HEAD^:apps/mobile/package.json' | node -p "JSON.parse(require('fs').readFileSync(0, 'utf8')).version")
if [[ "$mobile" == "$previous_version" ]]; then
  exit 0
fi
version_pr=$(gh api --paginate "repos/$GITHUB_REPOSITORY/commits/$GITHUB_SHA/pulls" --jq '.[] | select(.merged_at != null and .base.ref == "main" and .head.ref == "changeset-release/main") | .number')
if [[ -z "$version_pr" ]]; then
  echo 'Only a merged version pull request releases the hosts'
  exit 0
fi
tag="v$mobile"
existing=$(git ls-remote origin "refs/tags/$tag" | cut -f1)
if [[ -n "$existing" ]]; then
  git fetch origin "refs/tags/$tag"
  if [[ "$(git rev-parse 'FETCH_HEAD^{commit}')" != "$GITHUB_SHA" ]]; then
    echo 'The release tag points to another commit; refusing to upload it' >&2
    exit 1
  fi
else
  git tag "$tag" "$GITHUB_SHA"
  git push origin "refs/tags/$tag"
fi

# A tag alone does not prove that release creation or TestFlight completed.
# List through the API so a network/auth error fails rather than looking absent.
release=$(gh api --paginate "repos/$GITHUB_REPOSITORY/releases" --jq ".[] | select(.tag_name == \"$tag\") | .id")
if [[ -z "$release" ]]; then
  gh release create "$tag" --verify-tag --title "$tag" --generate-notes
fi
echo 'release=true' >> "$GITHUB_OUTPUT"
echo "tag=$tag" >> "$GITHUB_OUTPUT"
