#!/bin/zsh
set -euo pipefail
builtin cd -q "${0:A:h}/.."
app_path=${1:-}
source_app="${app_path:A}"
export UNWIRED_APP_PATH="$source_app"
if [[ ! -d "$UNWIRED_APP_PATH" || -z "${1:-}" ]]; then
  print -u2 'Usage: pnpm test:native /absolute/path/to/Testing/UnwiredMail.app'
  exit 1
fi
artifact_root="${PWD}/../../artifacts/macos-inbox"
mkdir -p "$artifact_root"
UNWIRED_TEST_ARTIFACTS=$(mktemp -d "$artifact_root/journey.XXXXXX")
export UNWIRED_TEST_ARTIFACTS
probe_dir=$(mktemp -d "$artifact_root/probe.XXXXXX")
bundle_id=""
cleanup() {
  local cleanup_exit=0
  if [[ -n "$bundle_id" ]]; then
    "$UNWIRED_TEST_ARTIFACTS/Cleanup.app/Contents/MacOS/cleanup" "$bundle_id" || cleanup_exit=$?
    # The sandbox gives each disposable identity its own container.
    if [[ "$bundle_id" =~ '^dev\.unwired\.mock\.[0-9a-f]{32}$' ]]; then
      rm -rf "$HOME/Library/Containers/$bundle_id" || cleanup_exit=1
    fi
  fi
  rm -rf "$probe_dir" "$UNWIRED_TEST_ARTIFACTS/Mock.app" "$UNWIRED_TEST_ARTIFACTS/cleanup" || cleanup_exit=1
  if (( cleanup_exit == 0 )); then
    rm -rf "$UNWIRED_TEST_ARTIFACTS/Cleanup.app" || cleanup_exit=1
  else
    print -u2 "Cleanup failed; retained the signed helper and ownership record: $UNWIRED_TEST_ARTIFACTS"
  fi
  return "$cleanup_exit"
}
trap 'run_exit=$?; cleanup || run_exit=1; print "{\"exitCode\":$run_exit,\"kind\":\"mock-mail-session\"}" > "$UNWIRED_TEST_ARTIFACTS/result.json"; exit "$run_exit"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
swiftc ../../scripts/cleanup-mock-macos.swift -o "$UNWIRED_TEST_ARTIFACTS/cleanup"
bundle_id=$(python3 ../../scripts/prepare-mock-app.py macos "$source_app" "$UNWIRED_TEST_ARTIFACTS/Mock.app" "$UNWIRED_TEST_ARTIFACTS/cleanup")
export UNWIRED_APP_PATH="$UNWIRED_TEST_ARTIFACTS/Mock.app"
: > "$UNWIRED_TEST_ARTIFACTS/lifecycle.jsonl"
export UNWIRED_TEST_SCENARIO=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["scenario"])' "$UNWIRED_TEST_ARTIFACTS/ownership.json")
cp native-tests/{WindowTests.swift,create-project.rb} "$probe_dir/"
builtin cd -q "$probe_dir"
"${RUBY:-ruby}" create-project.rb
xcodebuild test -project WindowProbe.xcodeproj -scheme WindowProbe \
  -destination 'platform=macOS' -test-timeouts-enabled YES \
  -maximum-test-execution-time-allowance 120 -derivedDataPath "$probe_dir/DerivedData" \
  -resultBundlePath "$UNWIRED_TEST_ARTIFACTS/WindowProbe.xcresult" CODE_SIGN_IDENTITY=- ARCHS=arm64 \
  | tee "$UNWIRED_TEST_ARTIFACTS/xcodebuild.log"
# A successful build with no executed journey is not test evidence.
/usr/bin/grep -q 'Executed 1 test, with 0 failures' "$UNWIRED_TEST_ARTIFACTS/xcodebuild.log"
print "Native evidence: $UNWIRED_TEST_ARTIFACTS"
