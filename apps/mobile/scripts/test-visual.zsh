#!/bin/zsh
set -uo pipefail

# Captures the visual journey through the native runner, then writes the visual report
# (docs/visual-report.md). Exits non-zero when the journey fails or the report is incomplete.
if [[ $# == 0 ]]; then
  print -u2 'Usage: pnpm test:visual /absolute/path/to/Release-iphonesimulator/UnwiredMail.app [simulator device type]'
  exit 2
fi
mobile_root="${0:A:h:h}"
repo_root="${mobile_root:h:h}"
device_type=${2:-com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro}
log=$(mktemp)
trap 'rm -f "$log"' EXIT
journey_exit=0
UNWIRED_JOURNEY=testInboxVisual zsh "$mobile_root/scripts/test-native.zsh" "$1" "$device_type" 2>&1 |
  tee "$log" || journey_exit=$?
run_dir=$(sed -n 's/^Native evidence: //p' "$log" | tail -1)
[[ -d $run_dir ]] || { print -u2 'The native runner left no evidence directory'; exit 1; }
# The newest result bundle holds the attempt that ran last.
results=("$run_dir"/*.xcresult(Nom))
if (( $#results > 0 )); then
  xcrun xcresulttool export attachments --path "$results[1]" --output-path "$run_dir/attachments" ||
    journey_exit=1
fi
report_exit=0
node "$repo_root/scripts/visual-report.mjs" --manifest "$mobile_root/visual/inbox.json" \
  --device "$device_type" --attachments "$run_dir/attachments" --out "$run_dir/visual-report" \
  --revision "$(/usr/libexec/PlistBuddy -c 'Print :UnwiredCommit' "$1/Info.plist" 2>/dev/null || print unstamped)" \
  --toolchain "$(xcodebuild -version | paste -sd ' ' -)" || report_exit=$?
print "Visual report: $run_dir/visual-report"
exit $(( journey_exit || report_exit ))
