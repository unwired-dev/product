#!/bin/zsh
# Runs the page's unattended evidence run on a disposable copy of a `categorization-spike` Testing
# build, for hosts where XCTest cannot enable Automation Mode without a password (run.zsh needs it).
# Usage: [SPIKE_APPEARANCE=light] autorun.zsh /path/to/Testing/UnwiredMail.app matrix|states|unavailable
# Evidence (the app's JSONL results and window captures) goes to artifacts/categorization-spike.*.
set -euo pipefail
source_app="${1:A}"
mode="$2"
[[ -d "$source_app" && "$mode" =~ '^(matrix|states|unavailable)$' ]] || {
  print -u2 'Usage: autorun.zsh App.app matrix|states|unavailable'; exit 1;
}
[[ $(/usr/libexec/PlistBuddy -c 'Print :UnwiredMockScenario' "$source_app/Contents/Info.plist") == categorization-spike ]] || {
  print -u2 'The run requires a categorization-spike Testing build'; exit 1;
}
root="${0:A:h:h:h:h}"
mkdir -p "$root/artifacts"
evidence=$(mktemp -d "$root/artifacts/categorization-spike.XXXXXX")
work=$(mktemp -d)
bundle="dev.unwired.mock.$(uuidgen | tr -d - | tr '[:upper:]' '[:lower:]')"
results="$HOME/Library/Containers/$bundle/Data/tmp/categorization-spike.jsonl"
cleanup() {
  [[ -f "$results" ]] && cp "$results" "$evidence/"
  osascript -e "quit app id \"$bundle\"" 2>/dev/null || true
  for _ in {1..20}; do pgrep -f "$work/UnwiredMail.app" > /dev/null || break; sleep 1; done
  pkill -f "$work/UnwiredMail.app" 2>/dev/null || true
  rm -rf "$work" "$HOME/Library/Containers/$bundle"
  print "Spike evidence: $evidence"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# A disposable identity keeps the ordinary app's container and data untouched.
cp -R "$source_app" "$work/UnwiredMail.app"
app="$work/UnwiredMail.app"
[[ "$mode" == unavailable ]] && rm -rf "$app/Contents/Resources/CategorizationSpike/models"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle" "$app/Contents/Info.plist"
codesign -d --entitlements :- "$source_app" > "$work/entitlements.plist" 2>/dev/null
codesign --force --deep --sign - --entitlements "$work/entitlements.plist" "$app"
# SPIKE_APPEARANCE=light forces the Aqua appearance for this app only; the system setting stays.
appearance=()
[[ "${SPIKE_APPEARANCE:-}" == light ]] && appearance=(--args -NSRequiresAquaSystemAppearance YES)
open -n --env "UNWIRED_SPIKE_AUTORUN=$([[ $mode == unavailable ]] && print states || print $mode)" "$app" $appearance

window() {
  swift -e 'import CoreGraphics; let p = CommandLine.arguments[1]
    let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
    for w in l where (w["kCGWindowOwnerPID"] as? Int).map(String.init) == p && (w["kCGWindowLayer"] as? Int) == 0 {
      print(w["kCGWindowNumber"]!); break }' "$(pgrep -f "$work/UnwiredMail.app" | head -1)"
}
capture() { screencapture -x -o -l"$(window)" "$evidence/$1.png"; }
lines() { [[ -f "$results" ]] && wc -l < "$results" | tr -d ' ' || print 0; }
wait_lines() {
  local deadline=$((SECONDS + $2))
  while (( $(lines) < $1 )); do
    (( SECONDS < deadline )) || { print -u2 "Timed out waiting for $1 results"; exit 1; }
    sleep 1
  done
}

sleep 15
case "$mode" in
  unavailable) capture unavailable ;;
  states)
    wait_lines 1 600; sleep 2; capture system-result
    wait_lines 2 600; sleep 2; capture custom-uncategorized
    sleep 23; capture benchmarking
    wait_lines 3 600; sleep 2; capture cancelled
    # The dismissal cancels the second benchmark, then releases the model.
    wait_lines 6 600; sleep 2; capture dismissed ;;
  matrix) wait_lines 43 14400 ;;
esac
