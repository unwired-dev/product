#!/bin/zsh
# Archive a host from the current checkout and upload it to TestFlight.
set -eo pipefail
root=${0:A:h:h}
platform=${1:-}
if [[ "$platform" != ios && "$platform" != macos && "$platform" != both ]]; then
  print -u2 'Usage: scripts/testflight.zsh ios|macos|both'
  exit 2
fi
if [[ -n "${UNWIRED_MOCK_SCENARIO:-}" ]]; then
  print -u2 'Mock Mail Sessions are never uploaded'
  exit 2
fi
team=${APPLE_DEVELOPMENT_TEAM:-${UNWIRED_DEVELOPMENT_TEAM:-}}
for name in ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_PATH UNWIRED_GOOGLE_CLIENT_ID UNWIRED_CONVEX_URL; do
  if [[ -z "${(P)name:-}" ]]; then
    print -u2 "Missing $name"
    exit 2
  fi
done
if [[ -z "$team" || ! -f "$ASC_KEY_PATH" ]]; then
  print -u2 'Missing APPLE_DEVELOPMENT_TEAM or the App Store Connect key file'
  exit 2
fi
export UNWIRED_BUILD_NUMBER=${UNWIRED_BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}
export UNWIRED_COMMIT=$(git -C "$root" rev-parse HEAD)
artifacts="$root/artifacts/testflight/$UNWIRED_BUILD_NUMBER"
mkdir -p "$artifacts"
authentication=(-allowProvisioningUpdates -authenticationKeyPath "${ASC_KEY_PATH:A}"
  -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
cat > "$artifacts/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$team</string>
</dict></plist>
PLIST

upload() {
  local host=$1 workspace=$2 destination=$3 info=$4
  local archive="$artifacts/$host.xcarchive"
  xcodebuild archive -workspace "$workspace" -scheme UnwiredMail -configuration Release \
    -destination "$destination" -archivePath "$archive" \
    -derivedDataPath "$artifacts/$host-DerivedData" "${authentication[@]}" \
    CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$team" "${@:5}" > "$artifacts/$host-archive.log" 2>&1
  # A distributed artifact must never be able to start a Mock Mail Session.
  local app=("$archive"/Products/Applications/*.app(N))
  if /usr/libexec/PlistBuddy -c 'Print :UnwiredMockScenario' "$app[1]/$info" >/dev/null 2>&1 ||
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app[1]/$info")" != "$UNWIRED_BUILD_NUMBER" ]]; then
    print -u2 "Refusing to upload $host: unexpected archive configuration"
    exit 1
  fi
  xcodebuild -exportArchive -archivePath "$archive" -exportPath "$artifacts/$host-export" \
    -exportOptionsPlist "$artifacts/ExportOptions.plist" "${authentication[@]}" \
    > "$artifacts/$host-upload.log" 2>&1
  rm -rf "$artifacts/$host-DerivedData"
  print "Uploaded $host $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app[1]/$info") ($UNWIRED_BUILD_NUMBER) from $UNWIRED_COMMIT"
}

if [[ "$platform" != macos ]]; then
  pnpm --dir "$root" --filter @private-email/mobile native:generate --clean --no-install
  (builtin cd -q "$root/apps/mobile/ios" && pod install)
  upload ios "$root/apps/mobile/ios/UnwiredMail.xcworkspace" 'generic/platform=iOS' Info.plist
fi
if [[ "$platform" != ios ]]; then
  export UNWIRED_BUILD_CONFIGURATION=Release UNWIRED_SIGNING_IDENTITY='Apple Development' UNWIRED_DEVELOPMENT_TEAM="$team"
  export PATH="$(ruby -e 'print Gem.bindir'):$PATH"
  pnpm --dir "$root" --filter @private-email/macos native:generate
  pnpm --dir "$root" --filter @private-email/macos native:pods
  upload macos "$root/apps/macos/macos/UnwiredMail.xcworkspace" 'generic/platform=macOS' Contents/Info.plist ARCHS=arm64
fi
print "TestFlight evidence: $artifacts"
