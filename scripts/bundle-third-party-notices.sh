#!/bin/sh
# Run after the production JS bundle is generated, before Xcode signs the app.
set -eu
if [ "$CONFIGURATION" = Debug ]; then exit 0; fi
script_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
cd "$script_dir/.."
source_packages=${UNWIRED_SOURCE_PACKAGES:-}
if [ -z "$source_packages" ]; then
  # Archive BUILD_DIR is nested under ArchiveIntermediates, unlike a normal
  # build. Locate the resolved graph beside an ancestor of either layout.
  source_parent=${BUILD_DIR:?}
  while [ ! -f "$source_parent/SourcePackages/workspace-state.json" ]; do
    next_parent=$(dirname "$source_parent")
    if [ "$next_parent" = "$source_parent" ]; then
      echo "error: resolved Swift packages not found; set UNWIRED_SOURCE_PACKAGES" >&2
      exit 1
    fi
    source_parent=$next_parent
  done
  source_packages="$source_parent/SourcePackages"
fi
"${NODE_BINARY:-node}" scripts/third-party-notices.mjs \
  "${SOURCEMAP_FILE:?}" "${PODS_ROOT:?}" "$source_packages" \
  "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
