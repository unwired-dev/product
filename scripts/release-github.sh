#!/usr/bin/env bash
# The Release workflow runs this after changesets/action pushed the release tag.
# The GitHub Release body is the mobile changelog section for the version. GitHub
# refuses a body over 125,000 characters, so a longer section is linked instead.
set -euo pipefail

tag=$1
notes=$(awk -v heading="## ${tag#v}" '
  $0 == heading { found = 1; next }
  found && /^## / { exit }
  found { print }
  END { if (!found) exit 1 }
' apps/mobile/CHANGELOG.md) || {
  echo "apps/mobile/CHANGELOG.md has no section for $tag" >&2
  exit 1
}
# Byte length, so multi-byte characters can only make the check stricter.
if (( $(printf '%s' "$notes" | wc -c) > 125000 )); then
  changelog="https://github.com/$GITHUB_REPOSITORY/blob/$tag/apps"
  notes="The changelog for $tag is too long for a GitHub Release. Read it in [apps/mobile/CHANGELOG.md]($changelog/mobile/CHANGELOG.md) and [apps/macos/CHANGELOG.md]($changelog/macos/CHANGELOG.md)."
fi
printf '%s\n' "$notes" | gh release create "$tag" --verify-tag --title "$tag" --notes-file -
