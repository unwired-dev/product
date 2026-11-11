#!/bin/sh
# Compile the verified Metro bundle to the Hermes bytecode the archive ships.
# Plain Metro maps cannot symbolicate Hermes stacks, so the composed map keeps
# the compiler's x_hermes_function_offsets. Run from apps/macos after pnpm build.
set -eu
root=${UNWIRED_MAC_BUNDLE_ROOT:-.}
cd "$root"
compiler=${HERMES_CLI_PATH:-${PODS_ROOT:?}/hermes-engine/destroot/bin/hermesc}
if [ ! -x "$compiler" ]; then
  echo "error: Hermes compiler missing at $compiler" >&2
  exit 1
fi
if [ ! -s dist/main.jsbundle ] || [ ! -s dist/main.jsbundle.map ]; then
  echo "error: dist/main.jsbundle and its Metro map must exist before Hermes compilation" >&2
  exit 1
fi
script_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
if [ -n "${COMPOSE_SOURCEMAP_PATH:-}" ]; then
  compose=$COMPOSE_SOURCEMAP_PATH
else
  compose=$(CDPATH= cd -- "$script_dir" && node -p "require('node:path').join(require('node:path').dirname(require.resolve('react-native/package.json')), 'scripts/compose-source-maps.js')")
fi
staged=$(mktemp -d)
trap 'rm -rf "$staged"' EXIT
"$compiler" -emit-binary -O -output-source-map -out "$staged/main.jsbundle" dist/main.jsbundle
node "$compose" dist/main.jsbundle.map "$staged/main.jsbundle.map" -o "$staged/composed.map"
mv "$staged/main.jsbundle" dist/main.jsbundle
mv "$staged/composed.map" dist/main.jsbundle.map
if [ -n "${SOURCEMAP_FILE:-}" ]; then
  mkdir -p "$(dirname "$SOURCEMAP_FILE")"
  cp dist/main.jsbundle.map "$SOURCEMAP_FILE"
fi
if [ -n "${TARGET_BUILD_DIR:-}" ] && [ -n "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" ]; then
  dest="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
  mkdir -p "$dest"
  cp dist/main.jsbundle "$dest/main.jsbundle"
fi
