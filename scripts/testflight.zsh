#!/bin/zsh
# Archive a host from the current checkout and upload it to TestFlight.
set -eo pipefail
root=${0:A:h:h}
if [[ "${UNWIRED_TESTFLIGHT_ENV_LOADED:-}" != 1 ]]; then
  exec node "$root/scripts/testflight-env.mjs" "$@"
fi
# The API key is read from its file, never inherited by project build phases.
unset UNWIRED_TESTFLIGHT_ENV_LOADED ASC_PRIVATE_KEY
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
if [[ ! "$team" =~ '^[0-9A-Za-z]{10}$' || ! -r "$ASC_KEY_PATH" || "${ASC_KEY_PATH:A}" == "$root"/* ]]; then
  print -u2 'Missing APPLE_DEVELOPMENT_TEAM or the App Store Connect key file'
  exit 2
fi
export UNWIRED_BUILD_NUMBER=${UNWIRED_BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}
if [[ ! "$UNWIRED_BUILD_NUMBER" =~ '^[0-9]{12}$' ]]; then
  print -u2 'Invalid UTC build number (expected YYYYMMDDHHMM)'
  exit 2
fi
export UNWIRED_COMMIT=$(git -C "$root" rev-parse HEAD)
umask 077
mkdir -p "$root/artifacts/testflight"
artifacts=$(mktemp -d "$root/artifacts/testflight/$UNWIRED_BUILD_NUMBER.XXXXXX")
cleanup() {
  local result=${1:-$?}
  print -r -- "Exit status: $result" >> "$artifacts/status.txt"
  rm -rf "$artifacts/ios-DerivedData" "$artifacts/macos-DerivedData"
}
trap cleanup EXIT
trap 'cleanup 130; trap - EXIT; exit 130' INT
trap 'cleanup 143; trap - EXIT; exit 143' TERM
print -r -- "Source: $UNWIRED_COMMIT; build: $UNWIRED_BUILD_NUMBER" > "$artifacts/status.txt"
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

# Xcode diagnostics can contain signing tokens. Keep raw logs local and publish
# only the fixed status evidence; never print untrusted log excerpts.
report() {
  print -u2 "Failed: $1"
  exit 1
}

# CocoaPods intermittently fails Pods project generation in pnpm workspaces
# (CocoaPods/CocoaPods#12866); a repeat succeeds.
pods() {
  for attempt in 1 2 3; do
    "$@" && return
  done
  print -u2 'CocoaPods installation failed'
  exit 1
}

upload() {
  local host=$1 workspace=$2 destination=$3 info=$4
  local archive="$artifacts/$host.xcarchive"
  local map="$artifacts/$host-sources/main.jsbundle.map"
  mkdir -p "${map:h}"
  print -r -- "Archiving: $host" >> "$artifacts/status.txt"
  xcodebuild archive -workspace "$workspace" -scheme UnwiredMail -configuration Release \
    -destination "$destination" -archivePath "$archive" \
    -derivedDataPath "$artifacts/$host-DerivedData" "${authentication[@]}" \
    CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$team" SOURCEMAP_FILE="$map" "${@:5}" > "$artifacts/$host-archive.log" 2>&1 ||
    report "$artifacts/$host-archive.log"
  # Inspect the trusted archive before distribution, including its packaged code.
  local app=("$archive"/Products/Applications/*.app(N))
  if (( ${#app} != 1 )); then
    print -u2 "Refusing to upload $host: expected one archived app"
    exit 1
  fi
  local package_host=$host
  if [[ "$host" == ios ]]; then package_host=mobile; fi
  local version=$(ruby -rjson -e 'print JSON.parse(File.read(ARGV[0])).fetch("version")' "$root/apps/$package_host/package.json")
  if /usr/libexec/PlistBuddy -c 'Print :UnwiredMockScenario' "$app[1]/$info" >/dev/null 2>&1 ||
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app[1]/$info" 2>/dev/null)" != "$UNWIRED_BUILD_NUMBER" ||
       "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app[1]/$info" 2>/dev/null)" != dev.unwired.mail ||
       "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app[1]/$info" 2>/dev/null)" != "$version" ||
       "$(/usr/libexec/PlistBuddy -c 'Print :UnwiredCommit' "$app[1]/$info" 2>/dev/null)" != "$UNWIRED_COMMIT" ||
       "$(/usr/libexec/PlistBuddy -c 'Print :UnwiredConvexURL' "$app[1]/$info" 2>/dev/null)" != "$UNWIRED_CONVEX_URL" ||
       "$(/usr/libexec/PlistBuddy -c 'Print :GIDClientID' "$app[1]/$info" 2>/dev/null)" != "$UNWIRED_GOOGLE_CLIENT_ID" ]]; then
    print -u2 "Refusing to upload $host: unexpected archive configuration"
    exit 1
  fi
  local resources="$app[1]" executable="$app[1]/UnwiredMail"
  if [[ "$host" == macos ]]; then
    resources="$app[1]/Contents/Resources"
    executable="$app[1]/Contents/MacOS/UnwiredMail"
  fi
  if [[ ! -s "$resources/main.jsbundle" || ! -s "$executable" || ! -s "$map" ]]; then
    print -u2 "Refusing to upload $host: missing bundle or native test paths"
    exit 1
  fi
  /usr/bin/strings -a "$executable" > "$artifacts/$host-native-strings.log" 2>&1 || report "$artifacts/$host-native-strings.log"
  if /usr/bin/grep -E 'UNWIRED_LIFECYCLE_PATH|MockGoogleRegistrationProvider|MockAppleRegistrationProvider|MockProductSyncBackend' "$artifacts/$host-native-strings.log" >/dev/null; then
    print -u2 "Refusing to upload $host: native test paths"
    exit 1
  fi
  rm "$artifacts/$host-native-strings.log"
  if [[ "$host" == ios ]]; then
    pnpm --dir "$root/apps/mobile" exec node scripts/verify-bundle.ts "${map:h}/" > "$artifacts/$host-inspection.log" 2>&1 || report "$artifacts/$host-inspection.log"
  else
    # The Mac archive phase verifies dist; bind that map and bundle to this archive.
    cmp "$map" "$root/apps/macos/dist/main.jsbundle.map" &&
      cmp "$resources/main.jsbundle" "$root/apps/macos/dist/main.jsbundle" || report "$artifacts/$host-inspection.log"
  fi
  print -r -- "Inspected: $host; production bundle, backend and native test boundary" >> "$artifacts/status.txt"
  xcodebuild -exportArchive -archivePath "$archive" -exportPath "$artifacts/$host-export" \
    -exportOptionsPlist "$artifacts/ExportOptions.plist" "${authentication[@]}" \
    > "$artifacts/$host-upload.log" 2>&1 || report "$artifacts/$host-upload.log"
  print -r -- "Uploaded: $host" >> "$artifacts/status.txt"
  ruby "$root/scripts/testflight-notes.rb" "$host" "$version" "$UNWIRED_BUILD_NUMBER" "$UNWIRED_COMMIT" > "$artifacts/$host-notes.log" 2>&1 || report "$artifacts/$host-notes.log"
  print -r -- "Test notes updated: $host" >> "$artifacts/status.txt"
  print "Uploaded $host $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app[1]/$info") ($UNWIRED_BUILD_NUMBER) from $UNWIRED_COMMIT"
}

if [[ "$platform" != macos ]]; then
  pnpm --dir "$root" --filter @private-email/mobile native:generate --clean --no-install
  pods pod install --project-directory="$root/apps/mobile/ios"
  upload ios "$root/apps/mobile/ios/UnwiredMail.xcworkspace" 'generic/platform=iOS' Info.plist
fi
if [[ "$platform" != ios ]]; then
  export UNWIRED_BUILD_CONFIGURATION=Release UNWIRED_SIGNING_IDENTITY='Apple Development' UNWIRED_DEVELOPMENT_TEAM="$team"
  export PATH="$(ruby -e 'print Gem.bindir'):$PATH"
  pnpm --dir "$root" --filter @private-email/macos native:generate
  pods pnpm --dir "$root" --filter @private-email/macos native:pods
  upload macos "$root/apps/macos/macos/UnwiredMail.xcworkspace" 'generic/platform=macOS' Contents/Info.plist ARCHS=arm64
fi
print "TestFlight evidence: $artifacts"
