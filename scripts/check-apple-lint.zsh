#!/usr/bin/env zsh
set -euo pipefail

missing_tools=()
swift_format_cmd=(swift-format)

if ! command -v swift-format >/dev/null 2>&1; then
  if xcrun -find swift-format >/dev/null 2>&1; then
    swift_format_cmd=(xcrun swift-format)
  else
    missing_tools+=(swift-format)
  fi
fi

if ! command -v swiftlint >/dev/null 2>&1; then
  missing_tools+=(swiftlint)
fi

if (( ${#missing_tools[@]} > 0 )); then
  print -u2 "Missing Apple lint tools: ${missing_tools[*]}"
  print -u2 "Run mise trust .mise.toml && mise install for SwiftLint and install Xcode or swift-format before running Apple lint checks."
  print -u2 "CI installs SwiftLint with mise and swift-format with Homebrew."
  exit 127
fi

"${swift_format_cmd[@]}" lint --recursive --strict apps/unwired-mail/unwired-mail apps/unwired-mail/unwired-mailTests
swiftlint lint --strict apps/unwired-mail
