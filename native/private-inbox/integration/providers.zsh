#!/bin/zsh
# Runs the iOS and Mac integration suites against the dedicated iCloud Mail and Seznam Email
# certification mailboxes. Run it under `op run --env-file <file outside the repository>`, which
# supplies UNWIRED_ICLOUD_ADDRESS, UNWIRED_SEZNAM_ADDRESS and their mail-client passwords,
# UNWIRED_ICLOUD_PASSWORD and UNWIRED_SEZNAM_PASSWORD. xcodebuild hands TEST_RUNNER_ variables to
# the test process, so no credential is written to the generated scheme.
set -euo pipefail
here=${0:A:h}
evidence="${here:h:h:h}/artifacts/private-inbox"
mkdir -p "$evidence"
started=$(mktemp "$evidence/providers.XXXXXX")
trap 'rm -f "$started"' EXIT
secrets=()
for key in ICLOUD_ADDRESS ICLOUD_PASSWORD SEZNAM_ADDRESS SEZNAM_PASSWORD; do
  name=UNWIRED_$key
  [[ -n "${(P)name:-}" ]] || { print -u2 "Missing $name"; exit 2; }
  export TEST_RUNNER_$name="${(P)name}"
  secrets+=("${(P)name}")
  unset $name
done
# iCloud Mail's IMAP user name, the name part of its address.
secrets+=("${secrets[1]%%@*}")
(( $# )) || set -- ios macos
result=0
for platform in "$@"; do
  zsh "$here/test.zsh" "$platform" || result=$?
done
# Neither address nor password reached the evidence of this run, passed or failed, nor the
# issues its compressed result bundles record. The patterns go to grep on a pipe, not as arguments.
found() { grep -qiF -f <(print -rl -- "${secrets[@]}") "$@"; }
for run in $(find "$evidence" -maxdepth 1 -name 'integration.*' -newer "$started"); do
  ! found -r "$run" || { print -u2 "Credential found in $run"; exit 1; }
  for bundle in "$run"/*.xcresult(N); do
    issues=$(xcrun xcresulttool get test-results tests --path "$bundle")
    ! print -r -- "$issues" | found || { print -u2 "Credential found in $bundle"; exit 1; }
  done
done
exit $result
