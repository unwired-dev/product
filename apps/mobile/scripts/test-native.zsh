#!/bin/zsh
set -euo pipefail

if [[ $# != 1 || ! -d "$1" || "$1" != *.app ]]; then
  print -u2 'Usage: pnpm test:native /absolute/path/to/Release-iphonesimulator/UnwiredMailPreview.app'
  exit 2
fi
app_bundle="${1:A}"
mobile_root="${0:A:h:h}"
repo_root="${mobile_root:h:h}"
mkdir -p "$repo_root/artifacts/expo-bootstrap"
run_dir=$(mktemp -d "$repo_root/artifacts/expo-bootstrap/native-XXXXXX")
print "Native evidence: $run_dir"
owned_devices=()
cleanup() {
  for device_id in "${owned_devices[@]}"; do
    xcrun simctl shutdown "$device_id" >/dev/null 2>&1 || true
    xcrun simctl delete "$device_id" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

cp "$mobile_root/native-tests/InboxTests.swift" "$run_dir/"
builtin cd -q "$run_dir"
# Use the Ruby installation that provides CocoaPods and its xcodeproj gem.
"${RUBY:-ruby}" "$mobile_root/native-tests/create-project.rb"
xcodebuild build-for-testing -project InboxProbe.xcodeproj -scheme InboxProbe \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$run_dir/DerivedData" CODE_SIGNING_ALLOWED=NO \
  > "$run_dir/build.log" 2>&1

for device_type in \
  com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro \
  com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M5-12GB; do
  device_id=$(xcrun simctl create "Inbox bootstrap ${run_dir:t}" "$device_type" com.apple.CoreSimulator.SimRuntime.iOS-27-0)
  owned_devices+=("$device_id")
  xcrun simctl boot "$device_id"
  xcrun simctl bootstatus "$device_id" -b
  xcrun simctl install "$device_id" "$app_bundle"
  xcodebuild test-without-building -project InboxProbe.xcodeproj -scheme InboxProbe \
    -destination "platform=iOS Simulator,id=$device_id" \
    -derivedDataPath "$run_dir/DerivedData" -resultBundlePath "$run_dir/$device_id.xcresult" \
    -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
    > "$run_dir/$device_id.log" 2>&1
  # Zero selected tests must never count as native journey evidence.
  rg -q 'Executed 1 test, with 0 failures' "$run_dir/$device_id.log"
  print "Native Inbox journey passed: $device_type"
  xcrun simctl shutdown "$device_id"
done
print "Native evidence: $run_dir"
