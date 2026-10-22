#!/bin/zsh
# Runs the assistance qualification corpus (#625) on this Mac from a disposable copy of an
# `assistance-qualification` Testing build, then removes the copy and its storage.
set -euo pipefail
builtin cd -q "${0:A:h}/.."
source_app="${1:-}"
if [[ -z "$source_app" || ! -d "$source_app" ]]; then
  print -u2 'Usage: pnpm qualify:assistance /absolute/path/to/Testing/UnwiredMail.app'
  exit 1
fi
source_app="${source_app:A}"
[[ $(/usr/libexec/PlistBuddy -c 'Print :UnwiredMockScenario' "$source_app/Contents/Info.plist") == assistance-qualification ]] || {
  print -u2 'The run requires an assistance-qualification Testing build'; exit 1;
}
artifact_root="${PWD}/../../artifacts/assistance-qualification"
mkdir -p "$artifact_root"
run=$(mktemp -d "$artifact_root/macos.XXXXXX")
bundle_id=""
cleanup() {
  local cleanup_exit=0
  if [[ -n "$bundle_id" ]]; then
    osascript -e "quit app id \"$bundle_id\"" 2>/dev/null || true
    for _ in {1..20}; do pgrep -f "$run/Mock.app/" > /dev/null || break; sleep 1; done
    pkill -f "$run/Mock.app/" 2>/dev/null || true
    # A copy that did not quit keeps its container for recovery with the retained helper.
    if "$run/Cleanup.app/Contents/MacOS/cleanup" "$bundle_id"; then
      rm -rf "$HOME/Library/Containers/$bundle_id" || cleanup_exit=1
    else
      cleanup_exit=$?
    fi
  fi
  rm -rf "$run/Mock.app" "$run/cleanup" || cleanup_exit=1
  if (( cleanup_exit == 0 )); then
    rm -rf "$run/Cleanup.app" || cleanup_exit=1
  else
    print -u2 "Cleanup failed; retained the signed helper and ownership record: $run"
  fi
  return "$cleanup_exit"
}
trap 'run_exit=$?; cleanup || run_exit=1; exit "$run_exit"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

swiftc ../../scripts/cleanup-mock-macos.swift -o "$run/cleanup"
bundle_id=$(python3 ../../scripts/prepare-mock-app.py macos "$source_app" "$run/Mock.app" "$run/cleanup")
results="$HOME/Library/Containers/$bundle_id/Data/tmp/assistance-qualification.jsonl"
open -n "$run/Mock.app"
# The app records one line per check and ends with `complete`, or `stopped` on an error.
deadline=$((SECONDS + ${UNWIRED_QUALIFICATION_TIMEOUT:-1800}))
until [[ -f "$results" ]] && /usr/bin/grep -Eq '"kind":"(complete|stopped)"' "$results"; do
  (( SECONDS < deadline )) || { print -u2 'Timed out waiting for the corpus run'; exit 1; }
  sleep 5
done
cp "$results" "$run/"
print "Assistance evidence: $run/assistance-qualification.jsonl"
python3 ../../scripts/verify-assistance-evidence.py "$run/assistance-qualification.jsonl"
# The manual checks use this copy; a relaunch writes new evidence to $results.
if [[ -n "${UNWIRED_QUALIFICATION_HOLD:-}" ]]; then
  print "Manual checks: the copy stays open; each relaunch rewrites $results"
  read -r '?Press Return to quit the copy and remove its data. '
fi
