#!/usr/bin/env bash
# dispatch-lost-work.sh -- a pass that lost its work must not report success.
# RUNNER: by hand -- the dispatcher on dexter calls this after each night's
# runs, pointed at that night's log directory (etalon#120, split from #118).
# GUARD-TEST: bin/tests/dispatch-lost-work.test.sh
#
# TRAPS: a log can say `=== result: success` and still have lost the commits
# -- a failed push or a failed salvage right beside it is the tell (#118's
# 2026-10-06 night: realisateur's fix-token-refresh-1504 and
# milestone-quality-survey, both logged SALVAGE FAILED next to result:
# success). Reads whichever logs it is given; no dexter path baked in.

set -uo pipefail

CLI_NAME='dispatch-lost-work.sh'
CLI_SUMMARY="does any log in a night's directory claim success while losing its work?"
CLI_USAGE='  dispatch-lost-work.sh --logs <dir>   census one log directory'
CLI_FLAGS='--logs'
CLI_EXITS='  0  no log in the directory claims success over a failed push or salvage
  1  a log claims success while a push or salvage in it failed
  2  usage error
  6  BLIND: no such directory, or no log files in it'
CLI_POSITIONAL=any
. "$(dirname "${BASH_SOURCE[0]}")/lib/cli-guard.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib/exit-codes.sh"
cli_guard "$@"

die2()    { printf '%s: %s\n' "$CLI_NAME" "$*" >&2; exit "$EXIT_USAGE"; }
dieblind(){ printf '%s: BLIND -- %s\n' "$CLI_NAME" "$*" >&2; exit "$EXIT_BLIND"; }

LOGDIR=''
while [ $# -gt 0 ]; do
  case "$1" in
    --logs) [ $# -ge 2 ] || die2 "--logs needs a directory"; LOGDIR="$2"; shift 2 ;;
    *) die2 "unexpected argument: $1" ;;
  esac
done
[ -n "$LOGDIR" ] || die2 "--logs <dir> is required"
[ -d "$LOGDIR" ] || dieblind "no such directory: $LOGDIR"

shopt -s nullglob
logs=("$LOGDIR"/*.log)
[ "${#logs[@]}" -gt 0 ] || dieblind "no log files in $LOGDIR -- refusing to report a clean night I did not read"

hits=()
for f in "${logs[@]}"; do
  grep -q '=== result: success' "$f" || continue
  grep -qE '=== SALVAGE FAILED|failed to push|! \[rejected\]' "$f" && hits+=("$f")
done

printf 'dispatch-lost-work -- %d of %d log(s) tonight claim success over lost work\n' \
  "${#hits[@]}" "${#logs[@]}"
for f in "${hits[@]}"; do
  printf '  %s\n' "$(basename "$f")"
done

if [ "${#hits[@]}" -gt 0 ]; then
  printf '  FLAG [dispatch-lost-work] result: success alongside a failed push or\n'
  printf '        salvage: the commits never landed. The issue needs a comment naming\n'
  printf '        the lost branch, and the same issue dispatched next.\n'
  exit "$EXIT_FINDING"
fi
printf '  ok -- no log claims success over lost work.\n'
exit "$EXIT_OK"
