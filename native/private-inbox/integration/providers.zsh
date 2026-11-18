#!/bin/zsh
# Runs the iOS and Mac integration suites against the dedicated iCloud Mail and Seznam Email
# certification mailboxes. Run it under `op run --env-file <file outside the repository>`, which
# supplies UNWIRED_ICLOUD_ADDRESS, UNWIRED_SEZNAM_ADDRESS and their mail-client passwords,
# UNWIRED_ICLOUD_PASSWORD and UNWIRED_SEZNAM_PASSWORD. test.zsh hands them to xcodebuild alone as
# TEST_RUNNER_ variables, which reach the test process without being written to the scheme.
set -euo pipefail
here=${0:A:h}
evidence="${here:h:h:h}/artifacts/private-inbox"
mkdir -p "$evidence"
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
# The runs' output is shown only once the scan below finds no credential in it.
output=$(mktemp "$evidence/providers.XXXXXX")
trap 'rm -f "$output"' EXIT
(( $# )) || set -- ios macos
result=0
runs=()
for platform in "$@"; do
  before=("$evidence"/integration.*(N/))
  (
    for index in {1..4}; do export TEST_RUNNER_UNWIRED_$keys[index]=$secrets[index]; done
    zsh "$here/test.zsh" "$platform"
  ) >> "$output" 2>&1 || result=$?
  after=("$evidence"/integration.*(N/))
  new=(${after:|before})
  runs+=($new)
  # A dropped variable would skip the certification test while the suite passes.
  logs=($^new/test-*.log(N))
  if ! { (( $#logs )) && grep -q 'swiftMailUsesTheCertificationMailboxes() passed' $logs; }; then
    print "The certification test did not pass on $platform" >> "$output"
    (( result )) || result=1
  fi
done
# Result bundles keep their data compressed, so each is kept only as the test results it records
# and every retained byte is scanned. No address, user name or password may reach this run's
# evidence, passed or failed; grep reports a match as 0 and a read error as 2.
scanned=0
for bundle in $^runs/*.xcresult(N); do
  xcrun xcresulttool get test-results tests --path "$bundle" > "${bundle:r}.json" || scanned=2
  rm -rf "$bundle"
done
(( scanned )) || grep -rqiF -f <(print -rl -- "${secrets[@]}") "$output" $runs || scanned=$?
if (( scanned != 1 )); then
  rm -rf $runs
  print -u2 "A credential was found in this run's evidence, or it could not be scanned; it was removed"
  exit 1
fi
cat "$output"
exit $result
