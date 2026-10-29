#!/bin/zsh
set -euo pipefail
root=${0:A:h:h:h:h}
[[ -n "${UNWIRED_STORAGE_PROFILE:-}" && -n "${UNWIRED_SIGNING_IDENTITY:-}" && -n "${UNWIRED_DEVELOPMENT_TEAM:-}" ]] || {
  print -u2 'Set UNWIRED_STORAGE_PROFILE, UNWIRED_SIGNING_IDENTITY and UNWIRED_DEVELOPMENT_TEAM for the entitled Mac storage probe.'
  exit 2
}
mkdir -p "$root/artifacts/private-inbox"
probe=$(mktemp -d "$root/artifacts/private-inbox/history.XXXXXX")
trap 'rm -rf "$probe/HistoryStore.app"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
app="$probe/HistoryStore.app"
mkdir -p "$app/Contents/MacOS"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.unwired.storage-probe.StorageHost</string>
<key>CFBundleExecutable</key><string>HistoryStore</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
cat > "$probe/entitlements.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.application-identifier</key><string>$UNWIRED_DEVELOPMENT_TEAM.dev.unwired.storage-probe.StorageHost</string>
<key>keychain-access-groups</key><array><string>$UNWIRED_DEVELOPMENT_TEAM.dev.unwired.storage-probe.StorageHost</string></array>
<key>com.apple.security.app-sandbox</key><true/>
</dict></plist>
PLIST
cp "$UNWIRED_STORAGE_PROFILE" "$app/Contents/embedded.provisionprofile"
xcrun swiftc -swift-version 6 -parse-as-library -target arm64-apple-macos27.0 \
  "$root/native/private-inbox/Sources/PrivateInbox/DeviceKeychain.swift" \
  "$root/native/private-inbox/Sources/PrivateInbox/PrivateInboxStore.swift" \
  "$root/native/private-inbox/integration/GmailHistoryStore.swift" \
  -o "$app/Contents/MacOS/HistoryStore"
codesign --force --sign "$UNWIRED_SIGNING_IDENTITY" --entitlements "$probe/entitlements.plist" "$app"
# Every mailbox, segment and body call crosses into the signed process, so journeys take longer.
UNWIRED_HISTORY_STORE_EXECUTABLE="$app/Contents/MacOS/HistoryStore" \
  pnpm --dir "$root" --filter @private-email/mail-core exec vitest run test/gmail-history.test.ts test/microsoft-history.test.ts \
  --testTimeout=15000 \
  > "$probe/journeys.log" 2>&1 || { cat "$probe/journeys.log"; exit 1; }
cat "$probe/journeys.log"
print "Gmail and Microsoft history with native storage evidence: $probe"
