#!/bin/zsh
# Build PostHog CLI 0.18.10 from the revision pinned in docs/telemetry.md.
# Published binaries ship their own telemetry, so this builds Release source
# with POSTHOG_API_TOKEN absent and a fresh target directory.
set -euo pipefail
destination=${1:?usage: scripts/build-posthog-cli.zsh <destination-binary>}
revision=e519ba6304903b31e5e3d74c6d1a5fe9a96c745e
expected=0.18.10
if ! command -v cargo >/dev/null; then
  curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable
  source "$HOME/.cargo/env"
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cli_source=$tmp/posthog
git clone --filter=blob:none --sparse --no-checkout https://github.com/PostHog/posthog.git "$cli_source"
git -C "$cli_source" sparse-checkout set cli
git -C "$cli_source" checkout --detach "$revision"
env -u POSTHOG_API_TOKEN -u POSTHOG_CLI_API_KEY \
  CARGO_TARGET_DIR="$cli_source/cli-target" CARGO_TERM_COLOR=never \
  cargo build --release --locked --manifest-path "$cli_source/cli/Cargo.toml"
built=$cli_source/cli-target/release/posthog-cli
version=$("$built" --version)
if [[ $version != *" $expected"* && $version != "$expected" ]]; then
  print -u2 "Expected posthog-cli $expected from $revision, got: $version"
  exit 1
fi
mkdir -p "${destination:h}"
cp "$built" "$destination"
chmod 755 "$destination"
print -r -- "$version"
