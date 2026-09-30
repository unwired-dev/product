#!/bin/zsh
set -euo pipefail
builtin cd -q "${0:A:h}/.."
configuration=${1:-Release}
export UNWIRED_BUILD_CONFIGURATION="$configuration"
if [[ -n "${UNWIRED_MOCK_SCENARIO:-}" && "$configuration" != Testing ]]; then
  print -u2 "Mock scenarios require Testing configuration"
  exit 2
fi
artifact_root="${PWD}/../../artifacts/macos-inbox"
mkdir -p "$artifact_root"
pnpm native:generate
pnpm native:pods
xcodebuild build -workspace macos/UnwiredMail.xcworkspace -scheme UnwiredMail \
  -configuration "$configuration" -destination 'platform=macOS' \
  -derivedDataPath "$artifact_root/DerivedData" CODE_SIGN_IDENTITY="${UNWIRED_SIGNING_IDENTITY:--}" ARCHS=arm64 ENABLE_HARDENED_RUNTIME=NO
