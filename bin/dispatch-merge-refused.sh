#!/usr/bin/env bash
# dispatch-merge-refused.sh -- a merge-carry refusal, flagged for requeue.
# RUNNER: by hand -- the dispatcher on dexter calls this after each night's
# runs, pointed at that night's log directory (etalon#123, split from #118).
# GUARD-TEST: bin/tests/dispatch-merge-refused.test.sh
#
# TRAPS: realisateur's agent/merge-carry.sh echoes
# "  FAILED   #<n> -- merge refused, kept for the next pass<note>" and changes
# nothing today (etalon#118). The act -- requeuing the PR's repo for the next
# pass -- is dispatcher-side, and hf7y-estate/realisateur#1587 (the held/
# frozen-PR taxonomy) is not ruled on yet. This verb's job ends at naming the
# refusal; etalon#123 draws that boundary on purpose, so do not grow this
# into deciding what "held" means.

set -uo pipefail

CLI_NAME='dispatch-merge-refused.sh'
CLI_SUMMARY="does a night's logs show a merge-carry refusal that needs requeue?"
CLI_USAGE='  dispatch-merge-refused.sh --logs <dir>   census one log directory'
CLI_FLAGS='--logs'
CLI_EXITS='  0  no log in the directory shows a merge-carry refusal
  1  at least one log shows "FAILED #<n> -- merge refused"
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

findings=()
for f in "${logs[@]}"; do
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    findings+=("$(basename "$f") #$n")
  done < <(grep -oE 'FAILED +#[0-9]+ -- merge refused' "$f" | grep -oE '[0-9]+')
done

printf 'dispatch-merge-refused -- %d merge-carry refusal(s) of %d log(s) tonight\n' \
  "${#findings[@]}" "${#logs[@]}"
for entry in "${findings[@]}"; do
  printf '  %s\n' "$entry"
done

if [ "${#findings[@]}" -gt 0 ]; then
  printf '  FLAG [dispatch-merge-refused] a merge was refused and kept for the next\n'
  printf '        pass. The PR named above needs the next pass on its repo --\n'
  printf '        requeuing it is dispatcher-side (hf7y-estate/realisateur#1587\n'
  printf '        still defines held vs. refused); this verb only names the refusal.\n'
  exit "$EXIT_FINDING"
fi
printf '  ok -- no merge-carry refusal tonight.\n'
exit "$EXIT_OK"
