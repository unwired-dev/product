#!/bin/sh
# git grep for implementers. Every reviewer-only source listed in
# docs/agents/implementation-review.md is excluded, whatever pathspecs the caller adds after `--`.
# Usage: scripts/implementer-grep.sh [git grep options] <pattern> [-- <pathspec>...]
set -eu

separated=false
for argument do
  if [ "$argument" = -- ]; then
    separated=true
  fi
done
if [ "$separated" = false ]; then
  set -- "$@" --
fi

exec git grep "$@" \
  ':(top,exclude)docs/architecture' \
  ':(top,exclude)docs/adr' \
  ':(top,exclude).patterns' \
  ':(top,exclude).opencodereview/rule.json' \
  ':(top,exclude).opencodereview/rules' \
  ':(top,exclude)docs/research' \
  ':(top,exclude)docs/qualification' \
  ':(top,exclude)docs/archive' \
  ':(top,exclude)artifacts/review-*'
