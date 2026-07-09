#!/usr/bin/env zsh
set -euo pipefail

missing_tools=()

for tool in swift-format swiftlint; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    missing_tools+=("$tool")
  fi
done

if (( ${#missing_tools[@]} > 0 )); then
  print -u2 "Missing Apple lint tools: ${missing_tools[*]}"
  print -u2 "Install swift-format and SwiftLint on PATH before running Apple formatting and lint checks."
  print -u2 "CI installs these with: brew install swift-format swiftlint"
  exit 127
fi

swift-format lint --recursive --strict apps/unwired-mail/unwired-mail apps/unwired-mail/unwired-mailTests
swiftlint lint apps/unwired-mail
