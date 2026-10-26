#!/bin/sh
# Appends a host-load snapshot to a native run's evidence so timing and idle-wait
# failures can be read against what else the shared host was doing.
# Usage: scripts/record-host-load.sh <file> <label>
# Never fails the run; unavailable observations are labelled rather than counted as zero.
file=$1
label=$2
{
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$label"
  uptime || printf 'load averages: unavailable\n'
  processes=$(pgrep -x xcodebuild)
  process_status=$?
  if [ "$process_status" -le 1 ]; then
    printf 'xcodebuild processes: %s\n' "$(printf '%s\n' "$processes" | grep -c '[0-9]')"
  else
    printf 'xcodebuild processes: unavailable\n'
  fi
  if devices=$(xcrun simctl list devices booted 2>/dev/null); then
    printf 'booted simulators: %s\n' "$(printf '%s\n' "$devices" | grep -c '(Booted)')"
  else
    printf 'booted simulators: unavailable\n'
  fi
} >>"$file" 2>/dev/null || true
