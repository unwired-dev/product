#!/bin/zsh
set -euo pipefail

if [[ $# != 1 || ! -d "$1" || "$1" != *.app ]]; then
  print -u2 'Usage: pnpm test:native /absolute/path/to/Release-iphonesimulator/UnwiredMailPreview.app'
  exit 2
fi
source_app="${1:A}"
mobile_root="${0:A:h:h}"
repo_root="${mobile_root:h:h}"
mkdir -p "$repo_root/artifacts/expo-bootstrap"
run_dir=$(mktemp -d "$repo_root/artifacts/expo-bootstrap/native-XXXXXX")
print "Native evidence: $run_dir"
owned_devices=()
cleanup() {
  local cleanup_exit=0
  for device_id in "${owned_devices[@]}"; do
    xcrun simctl shutdown "$device_id" >/dev/null 2>&1 || true
    xcrun simctl delete "$device_id" >/dev/null 2>&1 || cleanup_exit=1
  done
  rm -rf "$run_dir/Mock.app" "$run_dir/DerivedData" || cleanup_exit=1
  return "$cleanup_exit"
}
trap 'run_exit=$?; cleanup || run_exit=1; print "{\"exitCode\":$run_exit,\"kind\":\"mock-mail-session\"}" > "$run_dir/result.json"; exit "$run_exit"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

UNWIRED_BUNDLE_ID=$(python3 "$repo_root/scripts/prepare-mock-app.py" mobile "$source_app" "$run_dir/Mock.app")
export UNWIRED_BUNDLE_ID
export UNWIRED_TEST_SCENARIO=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["scenario"])' "$run_dir/ownership.json")
app_bundle="$run_dir/Mock.app"

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
  for attempt in 1 2; do
    device_id=$(xcrun simctl create "Inbox bootstrap ${run_dir:t}" "$device_type" com.apple.CoreSimulator.SimRuntime.iOS-27-0)
    owned_devices+=("$device_id")
    print "$device_id" >> "$run_dir/devices.txt"
    xcrun simctl boot "$device_id"
    xcrun simctl bootstatus "$device_id" -b
    xcrun simctl install "$device_id" "$app_bundle"
    test_exit=0
    xcodebuild test-without-building -project InboxProbe.xcodeproj -scheme InboxProbe \
      -destination "platform=iOS Simulator,id=$device_id" \
      -derivedDataPath "$run_dir/DerivedData" -resultBundlePath "$run_dir/$device_id.xcresult" \
      -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
      > "$run_dir/$device_id.log" 2>&1 || test_exit=$?
    if (( test_exit == 0 )) && grep -Eq 'Executed [1-9][0-9]* tests?, with 0 failures' "$run_dir/$device_id.log"; then
      print "Native Inbox journey passed: $device_type"
      xcrun simctl shutdown "$device_id"
      break
    fi
    # Assertion failures must never be hidden by an infrastructure retry.
    assertion_failed=0
    if grep -Eqi 'XCTAssert[^ ]* failed|Test Case .* failed|Executed [0-9]+ tests?, with [1-9][0-9]* failures?' "$run_dir/$device_id.log"; then
      assertion_failed=1
    fi
    if (( attempt == 1 && assertion_failed == 0 )) && {
      { (( test_exit == 0 )) && grep -Eq 'Executed 0 tests?, with 0 failures' "$run_dir/$device_id.log"; } ||
      grep -Eqi 'testmanagerd.*(socket.*(missing|not found|failed|unavailable)|failed to (connect|establish)|connection.*(invalid|interrupted|lost))|CoreSimulator.*(disconnected|connection.*invalid|service.*invalid)' "$run_dir/$device_id.log"
    }; then
      print -u2 "Simulator infrastructure failed; retrying once on a fresh device: $device_type"
      xcrun simctl shutdown "$device_id" >/dev/null 2>&1 || true
      continue
    fi
    tail -60 "$run_dir/$device_id.log" >&2
    print -u2 "Native Inbox journey failed: $device_type (attempt $attempt)"
    exit 1
  done
done
print "Native evidence: $run_dir"
