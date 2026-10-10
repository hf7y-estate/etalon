#!/usr/bin/env bash
# dispatch-turn-cap.sh -- a pass that used 90% or more of its turn cap, per log.
# RUNNER: by hand -- the dispatcher on dexter calls this after each night's
# runs, pointed at that night's log directory (etalon#125, split from #118).
# GUARD-TEST: bin/tests/dispatch-turn-cap.test.sh
#
# TRAPS: a pass that finishes with turns left and one that finishes nearly
# out of them look identical in "result: success" -- the header's declared
# cap and the result line's actual count are the only two numbers that say
# which. A log with either missing (crashed before a header, or before a
# result line) is not a measurable pass and is skipped, not guessed at.

set -uo pipefail

CLI_NAME='dispatch-turn-cap.sh'
CLI_SUMMARY='which pass logs used 90% or more of their configured turn cap?'
CLI_USAGE='  dispatch-turn-cap.sh --logs <dir>   census one log directory'
CLI_FLAGS='--logs'
CLI_EXITS='  0  no measurable pass used 90% or more of its turn cap
  1  at least one pass used 90% or more of its turn cap
  2  usage error
  6  BLIND: no such directory, or no measurable pass log in it'
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

measured=0
flags=()
for f in "${logs[@]}"; do
  cap="$(grep -m1 -E '^=== .* agent pass: .* \(turns=[0-9]+\) ===$' "$f" 2>/dev/null \
          | grep -oE 'turns=[0-9]+' | grep -oE '[0-9]+')" || cap=''
  actual="$(grep -E '^=== result: ' "$f" 2>/dev/null | tail -1 \
          | grep -oE 'turns=[0-9]+' | grep -oE '[0-9]+')" || actual=''
  if [ -z "$cap" ] || [ -z "$actual" ]; then continue; fi
  [ "$cap" -gt 0 ] || continue
  measured=$((measured + 1))
  # >=90% without floating point: actual*10 >= cap*9
  if [ $((actual * 10)) -ge $((cap * 9)) ]; then
    flags+=("$(basename "$f")|$actual|$cap")
  fi
done

[ "$measured" -gt 0 ] || dieblind "no log in $LOGDIR carries both a turn cap and a result line -- nothing measurable"

printf 'dispatch-turn-cap -- %d of %d measurable pass log(s) tonight used 90%% or more of their turn cap\n' \
  "${#flags[@]}" "$measured"

if [ "${#flags[@]}" -gt 0 ]; then
  for entry in "${flags[@]}"; do
    name="${entry%%|*}"; rest="${entry#*|}"; actual="${rest%%|*}"; cap="${rest#*|}"
    printf '  %s: %s/%s turns\n' "$name" "$actual" "$cap"
  done
  printf '  FLAG [dispatch-turn-cap] a pass this close to its cap finished (or was cut\n'
  printf '        off) without room to spare. Mark its issue too large: the next pass\n'
  printf '        on it must split, not continue (hf7y-estate/realisateur#1566).\n'
  exit "$EXIT_FINDING"
fi
printf '  ok -- every measurable pass had room left under its cap.\n'
exit "$EXIT_OK"
