#!/usr/bin/env bash
# Prints the `skip` output for the Mobile and Mac workflows: true for draft pull requests and
# pull requests that change only documentation, skills and Markdown, which no build reads.
# Pushes run everything. A failure prints nothing, so the dependent jobs run.
set -euo pipefail

if [[ $GITHUB_EVENT_NAME != pull_request ]]; then
  skip=false
elif [[ $DRAFT == true ]]; then
  skip=true
else
  # Renames would need blobs the blobless checkout lacks; names alone only need trees.
  changed=$(git diff --no-renames --name-only "$BASE_SHA...$HEAD_SHA" -- ':!docs' ':!.agents' ':!*.md')
  skip=$([[ -z $changed ]] && echo true || echo false)
fi
echo "skip=$skip"
