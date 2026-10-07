#!/usr/bin/env bash
# dispatch-auth-failures.sh -- auth failures mid-pass, counted per night.
# RUNNER: by hand -- the dispatcher on dexter calls this after each night's
# runs, pointed at that night's log directory (etalon#121, split from #118).
# GUARD-TEST: bin/tests/dispatch-auth-failures.test.sh
#
# TRAPS: a single expired token can knock out several passes in one night --
# that is one dispatcher-level failure, not several repo-level ones, so this
# counts LOGS, not occurrences, and names the dispatcher, never a repo.

set -uo pipefail

CLI_NAME='dispatch-auth-failures.sh'
CLI_SUMMARY="how many of a night's pass logs hit an authentication failure?"
CLI_USAGE='  dispatch-auth-failures.sh --logs <dir>   census one log directory'
CLI_FLAGS='--logs'
CLI_EXITS='  0  zero or one log in the directory shows an authentication failure
  1  more than one log shows an authentication failure this night
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
  grep -qE 'Authentication failed|HTTP (401|403)' "$f" && hits+=("$f")
done

printf 'dispatch-auth-failures -- %d of %d log(s) tonight hit an authentication failure\n' \
  "${#hits[@]}" "${#logs[@]}"
for f in "${hits[@]}"; do
  printf '  %s\n' "$(basename "$f")"
done

if [ "${#hits[@]}" -gt 1 ]; then
  printf '  FLAG [dispatch-auth-failures] more than one authentication failure\n'
  printf '        tonight: the dispatcher'"'"'s token is expiring mid-run, not any one\n'
  printf '        repo'"'"'s problem. File or update an issue on the dispatcher, not on\n'
  printf '        whichever repo happened to be running when it expired.\n'
  exit "$EXIT_FINDING"
fi
printf '  ok -- at most one authentication failure tonight.\n'
exit "$EXIT_OK"
