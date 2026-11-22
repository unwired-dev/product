#!/bin/zsh
# Hands certification credentials to the app on an iOS Simulator without any tool writing them to
# disk, then checks this Mac for them. The XCTest runner that drives the Simulator logs the text
# it types, so a credential is never typed: it is put on the Simulator's pasteboard and pasted in
# the app. Run it under `op run --env-file <file outside the repository>`, which supplies the
# named variables from the password manager.
#
#   copy <udid> <variable>           Put the variable's value on the Simulator's pasteboard.
#   clear <udid>                     Empty the Simulator's pasteboard.
#   scan <variable>... -- <path>...  List the files under the paths holding any value, also in
#                                    compressed result bundle data, which needs zstd. Exits 0
#                                    when none does, 1 on a match and 2 when a path is missing
#                                    or a file could not be read.
set -euo pipefail
usage() {
  print -u2 "Usage: ${ZSH_ARGZERO:t} copy <udid> <variable> | clear <udid> | scan <variable>... -- <path>..."
  exit 2
}
value() {
  [[ -n "${(P)1:-}" ]] || { print -u2 "Missing $1"; exit 2; }
  print -rn -- "${(P)1}"
}
case ${1:-} in
  copy)
    (( $# == 3 )) || usage
    value $3 | xcrun simctl pbcopy $2
    ;;
  clear)
    (( $# == 2 )) || usage
    xcrun simctl pbcopy $2 < /dev/null
    ;;
  scan)
    shift
    secrets=()
    while (( $# )) && [[ $1 != -- ]]; do secrets+=("$(value $1)"); shift; done
    (( $# )) && shift
    (( $#secrets && $# )) || usage
    paths=($@)
    for p in $paths; do [[ -e $p ]] || { print -u2 "Missing $p"; exit 2; }; done
    # Session transcripts are JSON, which escapes a backslash or quote in a value.
    for secret in $secrets; do secrets+=("${${secret//\\/\\\\}//\"/\\\"}"); done
    # grep reports a match as 0, none as 1 and a read error as 2.
    result=0
    LC_ALL=C grep -rlaFs -D skip -f <(print -rl -- $secrets) -- $paths || result=$?
    # Result bundles keep most of their data zstd-compressed, out of reach of a plain search;
    # the search above already read the rest. grep reads the whole stream, so an early match
    # cannot end zstd with SIGPIPE; a frame zstd cannot decode counts as a read error.
    bundles=(${^paths}/**/*.xcresult(ND/) ${(M)${paths:A}:#*.xcresult})
    set +e
    for blob in ${^bundles}/Data/*(N.); do
      [[ $(head -c 4 -- $blob | xxd -p) == 28b52ffd ]] || continue
      zstd -dcq -- $blob 2> /dev/null | LC_ALL=C grep -aF -f <(print -rl -- $secrets) > /dev/null
      codes=($pipestatus)
      if (( codes[2] == 0 )); then
        print -r -- $blob
        result=0
      elif (( (codes[1] || codes[2] > 1) && result == 1 )); then
        result=2
      fi
    done
    set -e
    exit $(( result == 0 ? 1 : result == 1 ? 0 : 2 ))
    ;;
  *) usage ;;
esac
