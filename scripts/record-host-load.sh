#!/bin/sh
# Appends a host-load snapshot to a native run's evidence so timing and idle-wait
# failures can be read against what else the shared host was doing.
# Usage: scripts/record-host-load.sh <file> <label>
# Never fails the run: a missing tool leaves its line out.
file=$1
label=$2
{
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$label"
  uptime
  printf 'xcodebuild processes: %s\n' "$(pgrep -x xcodebuild | wc -l | tr -d ' ')"
  printf 'booted simulators: %s\n' "$(xcrun simctl list devices booted 2>/dev/null | grep -c '(Booted)')"
} >>"$file" 2>/dev/null || true
