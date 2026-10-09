#!/bin/zsh
set -euo pipefail
root=${0:A:h:h:h:h}
mkdir -p "$root/scratchpad"
probe=$(mktemp -d "$root/scratchpad/draft-picker.XXXXXX")
trap 'rm -rf "$probe"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Compile the actual picker helpers in their own file scope, alongside the real native owners.
# Concatenation grants the fixture access to file-private helpers without exporting a test API.
cat "$root/native/private-inbox/bridge/DraftFilePicker.swift" \
  "$root/native/private-inbox/integration/DraftFilePickerTests.swift" > "$probe/PickerTests.swift"
xcrun swiftc -swift-version 6 -parse-as-library \
  "$root"/native/private-inbox/Sources/PrivateInbox/*.swift \
  "$probe/PickerTests.swift" -o "$probe/picker"
"$probe/picker" "$probe/files"
