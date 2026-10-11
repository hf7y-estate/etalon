#!/usr/bin/env bash
# thermostat-veto.sh -- non-inference veto on one merged PR's score.
# RUNNER: .github/workflows/tests.yml
# GUARD-TEST: bin/tests/thermostat-veto.test.sh
#
# Stage 1 of 4 in the thermostat (hf7y-estate/etalon#82, parent #79, Zach's
# ruling on #79's 2026-10-01 comment). This is a GATE, never a grade: it can
# only VETO a score, it never grants or raises one. Score, calibration and
# allocation are the later stages and are not built here.
#
# TRAPS: the pass's own /srv/agent/*.log format cannot be read from this
# container (needs-host) and is unconfirmed beyond the one data point on
# #79's comment (turns + cost on a `=== result` line). --log is therefore a
# best-effort SECOND source for "did tests run", never authoritative over
# CI, and its line shape (`=== result ... pr=N ... tests=pass|fail`) is a
# documented guess against representative fixtures, not a verified contract.
# Treat it as replaceable once a real log is readable.

set -uo pipefail

CLI_NAME='thermostat-veto.sh'
CLI_SUMMARY='non-inference veto gate on one merged PR -- stage 1 of the thermostat'
CLI_USAGE='  thermostat-veto.sh --repo <owner/repo> --pr <number> [--log <file>]'
CLI_FLAGS='--repo --pr --log'
CLI_EXITS='  0  no veto -- none of the non-inference checks fired
  1  VETO -- at least one non-inference check refused a score
  2  usage error
  6  BLIND: gh/jq missing, or the PR/issue could not be read (network, auth, 404)'
CLI_POSITIONAL=any
. "$(dirname "${BASH_SOURCE[0]}")/lib/cli-guard.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib/exit-codes.sh"
cli_guard "$@"

die2()    { printf '%s: %s\n' "$CLI_NAME" "$*" >&2; exit "$EXIT_USAGE"; }
dieblind(){ printf '%s: BLIND -- %s\n' "$CLI_NAME" "$*" >&2; exit "$EXIT_BLIND"; }

REPO=
PR=
LOG=
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) [ $# -ge 2 ] || die2 "--repo needs owner/repo"; REPO="$2"; shift 2 ;;
    --pr)   [ $# -ge 2 ] || die2 "--pr needs a number"; PR="$2"; shift 2 ;;
    --log)  [ $# -ge 2 ] || die2 "--log needs a file"; LOG="$2"; shift 2 ;;
    *) die2 "unexpected argument: $1" ;;
  esac
done
[ -n "$REPO" ] || die2 "--repo is required"
case "$PR" in ''|*[!0-9]*) die2 "--pr must be a number, got '$PR'" ;; esac
[ -z "$LOG" ] || [ -f "$LOG" ] || dieblind "no such log file: $LOG"

command -v gh >/dev/null 2>&1 || dieblind "gh is not on PATH"
command -v jq >/dev/null 2>&1 || dieblind "jq is not on PATH"

PR_JSON="$(gh pr view "$PR" --repo "$REPO" \
  --json state,mergedAt,files,closingIssuesReferences,statusCheckRollup 2>/dev/null)" \
  || dieblind "gh could not read $REPO#$PR (network, auth, or no such PR)"
printf '%s' "$PR_JSON" | jq -e . >/dev/null 2>&1 \
  || dieblind "gh returned unreadable JSON for $REPO#$PR"

VETOES=()

# -- check 1: tests ran -- a real pass/fail, not silence -------------------
ran_ci="$(printf '%s' "$PR_JSON" | jq -r '
  [.statusCheckRollup[]? | (.conclusion // .state // "")] | map(select(. != "")) | length')"
ran_log=0
if [ -n "$LOG" ] && grep -qE "^=== result.*\bpr=${PR}\b.*\btests=(pass|fail)\b" "$LOG" 2>/dev/null; then
  ran_log=1
fi
if [ "$ran_ci" -eq 0 ] && [ "$ran_log" -eq 0 ]; then
  VETOES+=("tests did not run (no completed CI check, and no pass-log evidence)")
fi

# -- check 2: the PR touched more than comments/prose -----------------------
mapfile -t FILES < <(printf '%s' "$PR_JSON" | jq -r '.files[]?.path')
if [ "${#FILES[@]}" -eq 0 ]; then
  VETOES+=("PR changed no files")
else
  nonprose=0
  for f in "${FILES[@]}"; do
    case "$f" in
      *.md|*.markdown|*.mdx|*.txt|*.rst) ;;
      *) nonprose=1 ;;
    esac
  done
  [ "$nonprose" -eq 1 ] || VETOES+=("PR touches only comments/prose (${FILES[*]})")
fi

# -- check 3: the closed issue has a stated done-when, and the diff is not a no-op --
mapfile -t ISSUES < <(printf '%s' "$PR_JSON" | jq -r '
  .closingIssuesReferences[]? | "\(.repository.owner.login)/\(.repository.name)#\(.number)"')
if [ "${#ISSUES[@]}" -eq 0 ]; then
  VETOES+=("PR closes no issue (nothing to hold a done-when against)")
else
  has_donewhen=0
  for nwo in "${ISSUES[@]}"; do
    irepo="${nwo%#*}"; inum="${nwo##*#}"
    ibody="$(gh issue view "$inum" --repo "$irepo" --json body --jq '.body' 2>/dev/null)" \
      || dieblind "gh could not read $nwo"
    case "$(printf '%s' "$ibody" | tr '[:upper:]' '[:lower:]')" in
      *'done when'*|*'acceptance criteria'*|*'definition of done'*) has_donewhen=1 ;;
    esac
  done
  if [ "$has_donewhen" -eq 0 ]; then
    VETOES+=("linked issue(s) ${ISSUES[*]} state no done-when/acceptance condition")
  else
    total="$(printf '%s' "$PR_JSON" | jq -r '[.files[]? | (.additions + .deletions)] | add // 0')"
    [ "${total:-0}" -gt 0 ] || VETOES+=("PR's diff is a no-op (0 lines changed)")
  fi
fi

if [ "${#VETOES[@]}" -gt 0 ]; then
  printf 'VETO %s\n' "${VETOES[0]}"
  if [ "${#VETOES[@]}" -gt 1 ]; then
    printf '  also vetoed on:\n'
    for v in "${VETOES[@]:1}"; do printf '    - %s\n' "$v"; done
  fi
  exit "$EXIT_FINDING"
fi
printf 'no veto\n'
exit "$EXIT_OK"
