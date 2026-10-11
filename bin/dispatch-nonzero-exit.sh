#!/usr/bin/env bash
# dispatch-nonzero-exit.sh -- a pass that exits non-zero needs an issue in
# its own repo, not just a log line.
# RUNNER: by hand -- the dispatcher on dexter calls this after each night's
# runs, pointed at that night's log directory (etalon#122, split from #118).
# GUARD-TEST: bin/tests/dispatch-nonzero-exit.test.sh
#
# TRAPS: realisateur's agent/nightly.sh:297 echoes
# "--- $label: pass exited $rc (its own log has the reason)" and nothing
# acts on it -- the 2026-10-06 night logged exactly that for wtul and
# realisateur (both "API Error: No response from API"), and both logs still
# say "=== result: success" despite it (etalon#118). #118's own words are
# "ONE issue in the repo it concerns" -- the failing repo, not a fixed
# dispatcher repo -- read from the log's own "starting pass on OWNER/REPO"
# line, never guessed from the filename alone. The filing key is that REPO,
# not the night or the log filename, so a second run on the same incident
# updates one issue instead of opening a second.

set -uo pipefail

CLI_NAME='dispatch-nonzero-exit.sh'
CLI_SUMMARY="does a night's logs show a pass that exited non-zero?"
CLI_USAGE='  dispatch-nonzero-exit.sh --logs <dir>
                                 census one log directory, printing the last
                                 20 lines of each flagged log
  dispatch-nonzero-exit.sh --logs <dir> --file-issue
                                 also file (or update, keyed on the failing
                                 repo, never duplicated) one issue in the
                                 repo named by each flagged pass own
                                 "starting pass on OWNER/REPO" line'
CLI_FLAGS='--logs --file-issue'
CLI_EXITS='  0  no log in the directory shows a non-zero pass exit
  1  at least one log shows "pass exited <rc>"
  2  usage error
  6  BLIND: no such directory, no log files in it, or (--file-issue) the API
     could not be read or written'
CLI_POSITIONAL=any
. "$(dirname "${BASH_SOURCE[0]}")/lib/cli-guard.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib/exit-codes.sh"
cli_guard "$@"

die2()    { printf '%s: %s\n' "$CLI_NAME" "$*" >&2; exit "$EXIT_USAGE"; }
dieblind(){ printf '%s: BLIND -- %s\n' "$CLI_NAME" "$*" >&2; exit "$EXIT_BLIND"; }

LOGDIR=''
FILE_ISSUE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --logs) [ $# -ge 2 ] || die2 "--logs needs a directory"; LOGDIR="$2"; shift 2 ;;
    --file-issue) FILE_ISSUE=1; shift ;;
    *) die2 "unexpected argument: $1" ;;
  esac
done
[ -n "$LOGDIR" ] || die2 "--logs <dir> is required"
[ -d "$LOGDIR" ] || dieblind "no such directory: $LOGDIR"

shopt -s nullglob
logs=("$LOGDIR"/*.log)
[ "${#logs[@]}" -gt 0 ] || dieblind "no log files in $LOGDIR -- refusing to report a clean night I did not read"

# The repo a pass concerns is read from its own "starting pass on
# OWNER/REPO" line (etalon#120's and #123's sibling verbs write that line
# into every fixture of this log shape) -- never guessed from the filename,
# which carries no owner and nothing for a cross-org repo.
owner_repo_of() { # <path>
  grep -m1 -oE 'starting pass on [^[:space:]]+/[^[:space:]]+' "$1" | awk '{print $NF}'
}

flagged_files=()
flagged_repos=()
flagged_rcs=()
for f in "${logs[@]}"; do
  rc_line="$(grep -m1 -E 'pass exited [0-9]+' "$f")" || continue
  rc="$(printf '%s\n' "$rc_line" | grep -oE 'pass exited [0-9]+' | grep -oE '[0-9]+$')"
  [ -n "$rc" ] || continue
  flagged_files+=("$f")
  flagged_repos+=("$(owner_repo_of "$f")")
  flagged_rcs+=("$rc")
done

printf 'dispatch-nonzero-exit -- %d of %d log(s) tonight show a non-zero pass exit\n' \
  "${#flagged_files[@]}" "${#logs[@]}"
for i in "${!flagged_files[@]}"; do
  printf '  %s -- pass exited %s\n' "$(basename "${flagged_files[$i]}")" "${flagged_rcs[$i]}"
  tail -n 20 "${flagged_files[$i]}" | sed 's/^/      /'
done

if [ "${#flagged_files[@]}" -eq 0 ]; then
  printf '  ok -- no pass exited non-zero tonight.\n'
  exit "$EXIT_OK"
fi

printf '  FLAG [dispatch-nonzero-exit] a pass exited non-zero and nothing but a log\n'
printf '        line said so (etalon#118). Each one above needs an issue in its own\n'
printf '        repo with the last 20 log lines, updated on a second occurrence, not\n'
printf '        duplicated.\n'

if [ "$FILE_ISSUE" -eq 1 ]; then
  GH_BIN="${DISPATCH_NONZERO_EXIT_GH:-gh}"
  for i in "${!flagged_files[@]}"; do
    target_repo="${flagged_repos[$i]}"
    [ -n "$target_repo" ] || dieblind "could not read the OWNER/REPO this pass concerns from $(basename "${flagged_files[$i]}")"
    title="dispatch-health: pass exited non-zero"
    body_lines="$(tail -n 20 "${flagged_files[$i]}")"
    body="Logged by dispatch-nonzero-exit.sh against $(basename "${flagged_files[$i]}") -- pass exited ${flagged_rcs[$i]}. Last 20 log lines:

\`\`\`
$body_lines
\`\`\`"

    EXISTING_JSON="$("$GH_BIN" api "repos/$target_repo/issues?state=open&per_page=100" --paginate 2>/dev/null)"
    [ -n "$EXISTING_JSON" ] || dieblind "could not read repos/$target_repo/issues to check for an existing filing"
    existing_num="$(printf '%s' "$EXISTING_JSON" | jq -r --arg t "$title" \
      'map(select(.title == $t)) | .[0].number // ""' 2>/dev/null)" \
      || dieblind "could not parse repos/$target_repo/issues"

    if [ -n "$existing_num" ]; then
      "$GH_BIN" api "repos/$target_repo/issues/$existing_num/comments" -f body="$body" >/dev/null \
        || dieblind "could not comment on $target_repo#$existing_num"
      printf '  filed: updated %s#%s\n' "$target_repo" "$existing_num"
    else
      NEW_JSON="$("$GH_BIN" api "repos/$target_repo/issues" -f title="$title" -f body="$body" 2>/dev/null)"
      new_num="$(printf '%s' "$NEW_JSON" | jq -r '.number // ""' 2>/dev/null)"
      [ -n "$new_num" ] || dieblind "could not file an issue on $target_repo"
      printf '  filed: opened %s#%s\n' "$target_repo" "$new_num"
    fi
  done
fi

exit "$EXIT_FINDING"
