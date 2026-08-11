#!/bin/zsh

set -u

if (( $# < 4 )) || [[ "$3" != '--' ]]; then
  print -u2 'usage: measure-ci-command.zsh <phase> <metrics-file> -- <command> [arguments...]'
  exit 64
fi

phase="$1"
metrics_file="$2"
shift 3

if [[ ! "$phase" =~ '^[a-z0-9-]+$' ]]; then
  print -u2 "invalid CI measurement phase: $phase"
  exit 64
fi

mkdir -p "${metrics_file:h}"
if [[ ! -s "$metrics_file" ]]; then
  print -r -- $'phase\tduration_seconds\tresult' > "$metrics_file"
fi

started_at="$(date +%s)"
"$@"
exit_code=$?
finished_at="$(date +%s)"
duration_seconds=$((finished_at - started_at))
result='success'
if (( exit_code != 0 )); then
  result='failure'
fi

printf '%s\t%s\t%s\n' "$phase" "$duration_seconds" "$result" >> "$metrics_file"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    if [[ ! -s "$GITHUB_STEP_SUMMARY" ]]; then
      print -r -- '| Phase | Duration | Result |'
      print -r -- '| --- | ---: | --- |'
    fi
    print -r -- "| $phase | ${duration_seconds}s | $result |"
  } >> "$GITHUB_STEP_SUMMARY"
fi

exit "$exit_code"
