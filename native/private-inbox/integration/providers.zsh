#!/bin/zsh
# Runs the iOS and Mac integration suites against the dedicated iCloud Mail and Seznam Email
# certification mailboxes. Run it under `op run --env-file <file outside the repository>`, which
# supplies UNWIRED_ICLOUD_ADDRESS, UNWIRED_SEZNAM_ADDRESS and their mail-client passwords,
# UNWIRED_ICLOUD_PASSWORD and UNWIRED_SEZNAM_PASSWORD. test.zsh hands them to xcodebuild alone as
# TEST_RUNNER_ variables, which reach the test process without being written to the scheme.
set -euo pipefail
keys=(ICLOUD_ADDRESS ICLOUD_PASSWORD SEZNAM_ADDRESS SEZNAM_PASSWORD)
secrets=()
for key in $keys; do
  name=UNWIRED_$key
  [[ -n "${(P)name:-}" ]] || { print -u2 "Missing $name"; exit 2; }
  secrets+=("${(P)name}")
  unset $name
done
# iCloud Mail's IMAP user name, the name part of its address.
secrets+=("${secrets[1]%%@*}")
here=${0:A:h}
evidence="${here:h:h:h}/artifacts/private-inbox"
mkdir -p "$evidence"
(( $# )) || set -- ios macos
# This run's evidence, one directory per host and the output buffer, is removed unless the scan
# below finds no credential in it; the output is shown only after that.
runs=()
for platform in "$@"; do runs+=("$(mktemp -d "$evidence/integration.XXXXXX")"); done
output=$(mktemp "$evidence/providers.XXXXXX")
scanned=0
trap 'rm -f "$output"; (( scanned == 1 )) || rm -rf $runs' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
result=0
for index in {1..$#}; do
  platform=${@[index]}
  (
    for key in {1..4}; do export TEST_RUNNER_UNWIRED_$keys[key]=$secrets[key]; done
    UNWIRED_STORAGE_PROBE=$runs[index] zsh "$here/test.zsh" "$platform"
  ) >> "$output" 2>&1 || result=$?
  # A dropped variable would skip the certification test while the suite passes.
  logs=($runs[index]/test-*.log(N))
  if ! { (( $#logs )) && grep -q 'swiftMailUsesTheCertificationMailboxes() passed' $logs; }; then
    print "The certification test did not pass on $platform" >> "$output"
    (( result )) || result=1
  fi
done
# Result bundles keep their data compressed, so each is kept only as the test results it records
# and every retained byte is scanned. No address, user name or password may reach this run's
# evidence, passed or failed; grep reports a match as 0, none as 1 and a read error as 2.
for bundle in $^runs/*.xcresult(N); do
  xcrun xcresulttool get test-results tests --path "$bundle" > "${bundle:r}.json" || scanned=2
  rm -rf "$bundle"
done
(( scanned )) || grep -rqiF -f <(print -rl -- "${secrets[@]}") "$output" $runs || scanned=$?
if (( scanned != 1 )); then
  print -u2 "A credential was found in this run's evidence, or it could not be scanned; it was removed"
  exit 1
fi
cat "$output"
exit $result
