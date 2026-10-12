#!/bin/zsh
set -euo pipefail
root=${0:A:h:h:h:h}
platform=${1:-ios}
[[ "$platform" == ios || "$platform" == macos ]] || { print -u2 'Expected ios or macos'; exit 2; }
(( $(df -k "$root" | awk 'NR == 2 {print $4}') >= 6 * 1024 * 1024 ))
zsh "$root/native/private-inbox/integration/metadata.zsh"
mkdir -p "$root/artifacts/private-inbox"
export UNWIRED_STORAGE_PROBE=$(mktemp -d "$root/artifacts/private-inbox/integration.XXXXXX")
owned_device=''
imap_server=''
cleanup() {
  if [[ -n "$imap_server" ]]; then
    kill -TERM "$imap_server" >/dev/null 2>&1 || true
    wait "$imap_server" >/dev/null 2>&1 || true
  fi
  if [[ -n "$owned_device" ]]; then
    xcrun simctl shutdown "$owned_device" >/dev/null 2>&1 || true
    xcrun simctl delete "$owned_device" >/dev/null 2>&1 || true
  fi
  rm -rf "$UNWIRED_STORAGE_PROBE/DerivedData"
  rm -f "$UNWIRED_STORAGE_PROBE/imap/ca.key" "$UNWIRED_STORAGE_PROBE/imap/server.key"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [[ "$platform" == ios ]]; then
  mkdir "$UNWIRED_STORAGE_PROBE/imap"
  node "$root/native/private-inbox/integration/imap-server.mjs" "$UNWIRED_STORAGE_PROBE/imap" \
    > "$UNWIRED_STORAGE_PROBE/imap/server.log" 2>&1 &
  imap_server=$!
  for ready in {1..100}; do
    [[ -f "$UNWIRED_STORAGE_PROBE/imap/port" ]] && break
    kill -0 "$imap_server" || { cat "$UNWIRED_STORAGE_PROBE/imap/server.log" >&2; exit 1; }
    sleep 0.1
  done
  export UNWIRED_IMAP_TLS_TEST_PORT=$(cat "$UNWIRED_STORAGE_PROBE/imap/port")
  [[ "$UNWIRED_IMAP_TLS_TEST_PORT" == <1-65535> ]]
fi
"${RUBY:-ruby}" "$root/native/private-inbox/integration/create-project.rb" "$platform"
for attempt in 1 2; do
  if [[ "$platform" == macos ]]; then
    destination='platform=macOS'
  else
    owned_device=$(xcrun simctl create "Private Inbox ${UNWIRED_STORAGE_PROBE:t}" com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro com.apple.CoreSimulator.SimRuntime.iOS-27-0)
    xcrun simctl boot "$owned_device"
    xcrun simctl bootstatus "$owned_device" -b
    # Only this run's disposable simulator trusts the generated synthetic CA.
    xcrun simctl keychain "$owned_device" add-root-cert "$UNWIRED_STORAGE_PROBE/imap/ca.pem"
    destination="platform=iOS Simulator,id=$owned_device"
  fi
  result=0
  log="$UNWIRED_STORAGE_PROBE/test-$attempt.log"
  xcodebuild test -project "$UNWIRED_STORAGE_PROBE/StorageProbe.xcodeproj" -scheme StorageProbe \
    -onlyUsePackageVersionsFromResolvedFile \
    -destination "$destination" -derivedDataPath "$UNWIRED_STORAGE_PROBE/DerivedData" \
    -resultBundlePath "$UNWIRED_STORAGE_PROBE/result-$attempt.xcresult" -parallel-testing-enabled NO \
    -test-timeouts-enabled YES -maximum-test-execution-time-allowance 120 \
    > "$log" 2>&1 || result=$?
  if (( result == 0 )) && grep -Eq 'Test run with 51 tests .* passed' "$log"; then
    if [[ -n "$imap_server" ]]; then
      kill -TERM "$imap_server"
      wait "$imap_server"
      imap_server=''
      [[ -f "$UNWIRED_STORAGE_PROBE/imap/result.json" ]]
    fi
    print "Private Inbox integration evidence: $UNWIRED_STORAGE_PROBE"
    exit 0
  fi
  if [[ "$platform" == ios && "$attempt" == 1 ]] &&
    ! grep -Eq 'Expectation failed|Caught error:|Test run .* failed' "$log" && {
      (( result == 0 )) || grep -Eqi 'testmanagerd.*(socket.*(missing|not found|failed|unavailable)|failed to (connect|establish)|connection.*(invalid|interrupted|lost))|CoreSimulator.*(disconnected|connection.*invalid|service.*invalid)' "$log"
    }; then
    xcrun simctl shutdown "$owned_device" >/dev/null 2>&1 || true
    xcrun simctl delete "$owned_device" >/dev/null 2>&1 || true
    owned_device=''
    continue
  fi
  tail -60 "$log" >&2
  exit 1
done
