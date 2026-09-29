#!/bin/zsh
set -euo pipefail
builtin cd -q "${0:A:h}/.."
app_path=${1:-}
export UNWIRED_APP_PATH="${app_path:A}"
if [[ ! -d "$UNWIRED_APP_PATH" || -z "${1:-}" ]]; then
  print -u2 'Usage: pnpm test:native /absolute/path/to/Testing/UnwiredMail.app'
  exit 1
fi
artifact_root="${PWD}/../../artifacts/macos-inbox"
mkdir -p "$artifact_root"
export UNWIRED_TEST_ARTIFACTS=$(mktemp -d "$artifact_root/journey.XXXXXX")
probe_dir=$(mktemp -d "$artifact_root/probe.XXXXXX")
trap 'rm -rf "$probe_dir"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
cp native-tests/{WindowTests.swift,create-project.rb} "$probe_dir/"
builtin cd -q "$probe_dir"
"${RUBY:-ruby}" create-project.rb
xcodebuild test -project WindowProbe.xcodeproj -scheme WindowProbe \
  -destination 'platform=macOS' -test-timeouts-enabled YES \
  -maximum-test-execution-time-allowance 120 -derivedDataPath "$probe_dir/DerivedData" \
  -resultBundlePath "$UNWIRED_TEST_ARTIFACTS/WindowProbe.xcresult" CODE_SIGN_IDENTITY=- ARCHS=arm64 \
  | tee "$UNWIRED_TEST_ARTIFACTS/xcodebuild.log"
# A successful build with no executed journey is not test evidence.
rg -q 'Executed 1 test, with 0 failures' "$UNWIRED_TEST_ARTIFACTS/xcodebuild.log"
print "Native evidence: $UNWIRED_TEST_ARTIFACTS"
