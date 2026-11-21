#!/bin/bash
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
  # A hung CoreSimulator never answers simctl (#1842): give it 10 s, then stop
  # its whole process group (bash job control), so no child keeps running.
  if devices=$(mktemp); then
    set -m
    xcrun simctl list devices booted </dev/null >"$devices" 2>/dev/null &
    pid=$!
    set +m
    deadline=$((SECONDS + 10))
    while kill -0 "$pid" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do
      sleep 0.1
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -s KILL -- "-$pid"
      wait "$pid"
      printf 'booted simulators: unavailable (timed out)\n'
    elif wait "$pid"; then
      printf 'booted simulators: %s\n' "$(grep -c '(Booted)' "$devices")"
    else
      printf 'booted simulators: unavailable\n'
    fi
    rm -f "$devices"
  else
    printf 'booted simulators: unavailable\n'
  fi
} >>"$file" 2>/dev/null || true
