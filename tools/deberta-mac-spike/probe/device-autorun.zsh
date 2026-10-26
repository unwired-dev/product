#!/bin/zsh
# Runs the page's unattended evidence run on a connected iPhone or iPad that already has a signed
# `categorization-spike` Release build installed. The device must stay unlocked with Auto-Lock off.
# Usage: device-autorun.zsh <device-udid> matrix|states
# Evidence (the app's JSONL results and screenshots) goes to artifacts/categorization-spike.*.
set -euo pipefail
device="$1"
mode="$2"
[[ "$mode" =~ '^(matrix|states)$' ]] || {
  print -u2 'Usage: device-autorun.zsh <device-udid> matrix|states'; exit 1;
}
root="${0:A:h:h:h:h}"
bundle=dev.unwired.mail
mkdir -p "$root/artifacts"
evidence=$(mktemp -d "$root/artifacts/categorization-spike.XXXXXX")
results="$evidence/categorization-spike.jsonl"
fetch() {
  xcrun devicectl device copy from --quiet --device "$device" --domain-type appDataContainer \
    --domain-identifier "$bundle" --source tmp/categorization-spike.jsonl --destination "$results" \
    2> /dev/null || true
}
cleanup() {
  fetch
  xcrun devicectl device info processes --quiet --device "$device" --json-output "$evidence/processes.json" 2> /dev/null || true
  pid=$(jq -r '.result.runningProcesses[] | select(.executable | test("UnwiredMail.app/UnwiredMail$")) | .processIdentifier' \
    "$evidence/processes.json" 2> /dev/null | head -1)
  [[ -n "$pid" ]] && xcrun devicectl device process terminate --quiet --device "$device" --pid "$pid" 2> /dev/null || true
  rm -f "$evidence/processes.json"
  print "Spike evidence: $evidence"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

xcrun devicectl device info details --quiet --device "$device" --json-output "$evidence/device.json"
# The bridge appends to its results, so an empty file replaces the previous run's.
: > "$evidence/empty.jsonl"
xcrun devicectl device copy to --quiet --device "$device" --domain-type appDataContainer \
  --domain-identifier "$bundle" --source "$evidence/empty.jsonl" --destination tmp/categorization-spike.jsonl
rm "$evidence/empty.jsonl"
xcrun devicectl device process launch --quiet --device "$device" --terminate-existing \
  --environment-variables "{\"UNWIRED_SPIKE_AUTORUN\":\"$mode\"}" "$bundle"

capture() {
  xcrun devicectl device capture screenshot --quiet --device "$device" --destination "$evidence/$1.png"
}
lines() { fetch; [[ -f "$results" ]] && wc -l < "$results" | tr -d ' ' || print 0; }
wait_lines() {
  local deadline=$((SECONDS + $2))
  while (( $(lines) < $1 )); do
    (( SECONDS < deadline )) || { print -u2 "Timed out waiting for $1 results"; exit 1; }
    sleep 5
  done
}

sleep 15
case "$mode" in
  states)
    wait_lines 1 600; sleep 2; capture system-result
    wait_lines 2 600; sleep 2; capture custom-uncategorized
    sleep 20; capture benchmarking
    wait_lines 3 600; sleep 2; capture cancelled
    # The dismissal cancels the second benchmark, then releases the model.
    wait_lines 6 600; sleep 2; capture dismissed
    mise exec -- uv run --project "$root/tools/deberta-mac-spike" python \
      "$root/tools/deberta-mac-spike/summarize.py" --check-states "$results" \
      > "$evidence/host-tables.md" ;;
  matrix)
    wait_lines 43 28800
    mise exec -- uv run --project "$root/tools/deberta-mac-spike" python \
      "$root/tools/deberta-mac-spike/summarize.py" --check-matrix "$results" \
      > "$evidence/host-tables.md" ;;
esac
