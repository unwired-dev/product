#!/bin/zsh
set -euo pipefail
root=${0:A:h:h:h:h}
mkdir -p "$root/scratchpad"
probe=$(mktemp -d "$root/scratchpad/synthetic-metadata.XXXXXX")
trap 'rm -rf "$probe"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
xcrun swiftc -swift-version 6 -parse-as-library -DUNWIRED_REGISTRATION_MOCK \
  "$root"/native/private-inbox/Sources/PrivateInbox/*.swift \
  "$root/native/private-inbox/bridge/SyntheticRegistration.swift" \
  "$root/native/private-inbox/integration/SyntheticMetadataTests.swift" \
  -o "$probe/metadata"
"$probe/metadata"
