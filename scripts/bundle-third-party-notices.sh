#!/bin/sh
# Run after the production JS bundle is generated, before Xcode signs the app.
set -eu
if [ "$CONFIGURATION" = Debug ]; then exit 0; fi
script_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
cd "$script_dir/.."
source_packages=${UNWIRED_SOURCE_PACKAGES:-$BUILD_DIR/../../SourcePackages}
"${NODE_BINARY:-node}" scripts/third-party-notices.mjs \
  "${SOURCEMAP_FILE:?}" "${PODS_ROOT:?}" "$source_packages" \
  "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
