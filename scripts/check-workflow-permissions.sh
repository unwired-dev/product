#!/usr/bin/env bash
# Fails unless every workflow grants only `contents: read` at the top level and
# every actions/checkout step sets `persist-credentials: false`.
# Usage: scripts/check-workflow-permissions.sh [workflow-dir]

set -euo pipefail

workflow_dir=${1:-"$(dirname -- "${BASH_SOURCE[0]}")/../.github/workflows"}

awk '
  function fail(file, message) {
    printf "%s: %s\n", file, message > "/dev/stderr"
    failed = 1
  }
  function end_checkout() {
    if (checkout && !persist) fail(file, "checkout at line " checkout " must set persist-credentials: false")
    checkout = 0
  }
  function end_file() {
    end_checkout()
    if (permissions != "contents: read") fail(file, "top-level permissions must be exactly contents: read")
  }
  FNR == 1 {
    if (file != "") end_file()
    file = FILENAME; in_permissions = 0; permissions = ""
  }
  /^[ \t]*(#|$)/ { next }
  {
    match($0, /^ */); indent = RLENGTH
  }
  checkout && indent <= step_indent { end_checkout() }
  in_permissions && indent == 0 { in_permissions = 0 }
  in_permissions {
    entry = $0; sub(/^ +/, "", entry)
    permissions = permissions (permissions == "" ? "" : ", ") entry
    next
  }
  /^permissions:/ { in_permissions = 1; next }
  /uses: actions\/checkout@/ {
    checkout = FNR; persist = 0
    step_indent = ($0 ~ /^ *- +uses:/) ? indent : indent - 2
  }
  checkout && /persist-credentials: false/ { persist = 1 }
  END { if (file != "") end_file(); exit failed }
' "$workflow_dir"/*.yml
