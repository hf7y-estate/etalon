#!/usr/bin/env bash
# dispatch-held-prs.sh -- a repo's open PRs, counted and aged, and whether
# every single one is held (etalon#124, split from #118).
# RUNNER: by hand -- this reads OTHER repos over the GitHub API; a live
#   estate-wide scan does not belong in this repo's own pull-request CI,
#   the same reason bin/guard-coverage.sh is not wired into tests.yml
#   (etalon#142).
# GUARD-TEST: bin/tests/dispatch-held-prs.test.sh
#
# TRAPS: "held" has no estate-wide ruling yet (hf7y-estate/realisateur#1587
# is the open taxonomy question, listed as DEFERRED on etalon#118). This
# tool picks ONE concrete, documented signal instead of waiting on that
# ruling: GitHub's own `mergeStateStatus == BLOCKED` on a non-draft PR --
# the state GitHub assigns when a required status check is failing or a
# required review is outstanding. A PR this tool cannot read the
# mergeStateStatus of is never silently excluded; that is a BLIND exit.

set -uo pipefail

CLI_NAME='dispatch-held-prs.sh'
CLI_SUMMARY='does a repo have open PRs, and are they ALL held?'
CLI_USAGE='  dispatch-held-prs.sh OWNER/REPO [OWNER/REPO ...]
      census open PRs per named repo(s) over the GitHub API: how many are
      open, how many are held (mergeStateStatus BLOCKED, not a draft), and
      each held PR'"'"'s age in days since it was opened'
CLI_FLAGS=''
CLI_EXITS='  0  every repo checked has no open PRs, or at least one that is not held
  1  at least one repo checked has one or more open PRs and ALL of them held
  2  usage error
  6  BLIND: a repo'"'"'s open-PR list could not be read from the API'
CLI_POSITIONAL=any
. "$(dirname "${BASH_SOURCE[0]}")/lib/cli-guard.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib/exit-codes.sh"
cli_guard "$@"

die2()    { printf '%s: %s\n' "$CLI_NAME" "$*" >&2; exit "$EXIT_USAGE"; }
dieblind(){ printf '%s: BLIND -- %s\n' "$CLI_NAME" "$*" >&2; exit "$EXIT_BLIND"; }

[ $# -gt 0 ] || die2 "at least one OWNER/REPO is required"
for a in "$@"; do
  case "$a" in
    */*) ;;
    *) die2 "not an OWNER/REPO: $a" ;;
  esac
done

GH_BIN="${DISPATCH_HELD_PRS_GH:-gh}"
NOW="${DISPATCH_HELD_PRS_NOW:-$(date -u +%s)}"

age_days() { # <iso8601-timestamp> -> whole days between it and $NOW
  local t
  t="$(date -u -d "$1" +%s 2>/dev/null)" || t="$(date -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null)"
  [ -n "$t" ] || { printf '?'; return; }
  printf '%d' "$(( (NOW - t) / 86400 ))"
}

open_prs_of() { # <owner/repo> -> sets PR_JSON, raw array from the API
  local out rc
  out="$("$GH_BIN" pr list --repo "$1" --state open --limit 200 \
    --json number,createdAt,isDraft,mergeStateStatus 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] || dieblind "could not read $1's open PRs from the API: $out"
  PR_JSON="$out"
  printf '%s' "$PR_JSON" | jq -e . >/dev/null 2>&1 \
    || dieblind "$1's open-PR list was not the JSON the API promises"
}

checked=0
all_held_repos=''
while [ $# -gt 0 ]; do
  repo="$1"; shift
  checked=$((checked + 1))
  open_prs_of "$repo"

  total="$(printf '%s' "$PR_JSON" | jq 'length')"
  held_lines="$(printf '%s' "$PR_JSON" | jq -r '
    .[] | select(.isDraft == false and .mergeStateStatus == "BLOCKED") |
    "\(.number)\t\(.createdAt)"')"

  if [ "$total" -eq 0 ]; then
    printf 'dispatch-held-prs -- %s has 0 open PR(s)\n' "$repo"
    continue
  fi

  held_count=0
  [ -n "$held_lines" ] && held_count="$(printf '%s\n' "$held_lines" | grep -c .)"

  printf 'dispatch-held-prs -- %s: %d of %d open PR(s) held\n' "$repo" "$held_count" "$total"
  if [ -n "$held_lines" ]; then
    while IFS=$'\t' read -r num created; do
      [ -n "$num" ] || continue
      printf '  #%s (%sd old)\n' "$num" "$(age_days "$created")"
    done <<EOF
$held_lines
EOF
  fi

  if [ "$held_count" -eq "$total" ]; then
    all_held_repos="$all_held_repos$repo"$'\n'
  fi
done

[ "$checked" -gt 0 ] || dieblind "no repo was checked"

if [ -n "$all_held_repos" ]; then
  n="$(printf '%s' "$all_held_repos" | grep -c .)"
  printf '  FLAG [dispatch-held-prs] %d repo(s) have EVERY open PR held (etalon#124):\n' "$n"
  printf '%s' "$all_held_repos" | sed 's/^/        /'
  exit "$EXIT_FINDING"
fi
printf '  ok -- no checked repo has every open PR held.\n'
exit "$EXIT_OK"
