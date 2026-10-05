#!/usr/bin/env bash
# will-it-run.sh -- does hf7y-estate/<repo>#<n> get picked up by the nightly
# dispatcher, and if not, why.
# RUNNER: .github/workflows/tests.yml
# GUARD-TEST: bin/tests/will-it-run.test.sh
#
# TRAPS: realisateur's agent/nightly.sh carries the queue predicate, not a
# copy of it kept here. This fetches that script's text at call time and
# extracts its literal gh/jq fragments instead of re-deriving the predicate
# by hand, so a predicate edit there changes what this reports on the very
# next run instead of silently drifting out of sync with it. There is no
# ordering left to report: realisateur#1420 (2026-10-03) deleted the `first`
# label, so the queue is exactly the three checks below -- open, in an open
# milestone, neither needs-host nor needs-human -- and order is whatever
# `nightly.sh --send 1 repo#n ...` is told, which skips the queue entirely.

set -uo pipefail

CLI_NAME='will-it-run.sh'
CLI_SUMMARY='does hf7y-estate/<repo>#<n> get a nightly pass, and if not, why?'
CLI_USAGE='  will-it-run.sh <repo> <issue-number>   e.g. will-it-run.sh etalon 80'
CLI_FLAGS=''
CLI_EXITS='  0  RUNS -- the issue is in the dispatchers queue
  1  WILL NOT RUN -- a reason is printed, with the command to force a pass
  2  usage error
  6  BLIND: a gh/api call failed, or the queue predicate could not be read'
CLI_POSITIONAL=any
. "$(dirname "${BASH_SOURCE[0]}")/lib/cli-guard.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib/exit-codes.sh"
cli_guard "$@"

die2()    { printf '%s: %s\n' "$CLI_NAME" "$*" >&2; exit "$EXIT_USAGE"; }
dieblind(){ printf '%s: BLIND -- %s\n' "$CLI_NAME" "$*" >&2; exit "$EXIT_BLIND"; }

[ $# -eq 2 ] || die2 "want exactly 2 arguments: <repo> <issue-number>, got $#"
REPO="$1"
N="$2"
case "$N" in ''|*[!0-9]*) die2 "issue number must be digits, got '$N'" ;; esac
case "$REPO" in ''|*[!A-Za-z0-9._-]*) die2 "repo name looks wrong: '$REPO'" ;; esac

GH="${WILL_IT_RUN_GH:-gh}"
sq="'"

# run-agent.sh, for the default turns it hands the brief and to confirm its
# argument order has not changed shape under this.
run_agent_src="$("$GH" api repos/hf7y-estate/realisateur/contents/agent/run-agent.sh --jq .content 2>/dev/null | base64 -d 2>/dev/null)"
[ -n "$run_agent_src" ] || dieblind "cannot read realisateur's agent/run-agent.sh"
case "$run_agent_src" in
  *'run-agent.sh <repo> [max_turns] [issue]'*) ;;
  *) dieblind "run-agent.sh's argument contract changed shape -- refusing to print an unverified forcing command" ;;
esac
TURNS_DEFAULT="$(printf '%s\n' "$run_agent_src" | sed -n 's/.*turns="\${2:-\([0-9]*\)}".*/\1/p' | head -1)"
[ -n "$TURNS_DEFAULT" ] || dieblind "could not read run-agent.sh's default turns"

force_line() {
  printf 'to send a pass now:\n  ssh dexter %s/srv/agent/run-agent.sh %s %s %s%s\n' \
    "$sq" "$REPO" "$TURNS_DEFAULT" "$N" "$sq"
}

not_dispatched() {
  printf 'WILL NOT RUN -- hf7y-estate/%s is not dispatched (absent from realisateurs agent/repos and the hf7y-estate org)\n' "$REPO"
  force_line
  exit "$EXIT_FINDING"
}

# Dispatched means: named in realisateur's agent/repos, or present in the
# hf7y-estate org -- the org is the candidate set, agent/repos only orders it.
agent_repos_src="$("$GH" api repos/hf7y-estate/realisateur/contents/agent/repos --jq .content 2>/dev/null | base64 -d 2>/dev/null)"
[ -n "$agent_repos_src" ] || dieblind "cannot read realisateur's agent/repos"
in_list=0
while IFS= read -r r; do
  [ "$r" = "$REPO" ] && { in_list=1; break; }
done < <(printf '%s\n' "$agent_repos_src" | grep -vE '^[[:space:]]*(#|$)')

org_repos="$("$GH" repo list hf7y-estate --no-archived --limit 1000 --json name --jq '.[].name' 2>/dev/null)"
[ -n "$org_repos" ] || dieblind "cannot list the hf7y-estate org"
in_org=0
while IFS= read -r r; do
  [ "$r" = "$REPO" ] && { in_org=1; break; }
done <<<"$org_repos"

[ "$in_list" -eq 1 ] || [ "$in_org" -eq 1 ] || not_dispatched

# The issue itself.
issue_json="$("$GH" issue view "$N" --repo "hf7y-estate/$REPO" --json number,state,title,labels,milestone 2>/dev/null)"
[ -n "$issue_json" ] || dieblind "cannot read hf7y-estate/$REPO#$N"
state="$(printf '%s' "$issue_json" | jq -r '.state')"
labels="$(printf '%s' "$issue_json" | jq -r '.labels[]?.name')"
issue_ms="$(printf '%s' "$issue_json" | jq -r '.milestone.number // "null"')"

# nightly.sh's own queue predicate -- read fresh, not restated by hand.
nightly_src="$("$GH" api repos/hf7y-estate/realisateur/contents/agent/nightly.sh --jq .content 2>/dev/null | base64 -d 2>/dev/null)"
[ -n "$nightly_src" ] || dieblind "cannot read realisateur's agent/nightly.sh"
body="$(printf '%s\n' "$nightly_src" | sed -n '/^queue_count() {/,/^}/p')"
[ -n "$body" ] || dieblind "agent/nightly.sh has no queue_count() -- its predicate moved or was renamed"

ms_line="$(printf '%s\n' "$body" | grep 'gh api "repos/hf7y-estate')"
ms_api_path="$(printf '%s\n' "$ms_line" | sed -n 's/.*gh api "\([^"]*\)".*/\1/p')"
ms_jq="$(printf '%s\n' "$ms_line" | cut -d"'" -f2)"
issue_line="$(printf '%s\n' "$body" | grep 'gh issue list --repo "hf7y-estate')"
issue_repo_path="$(printf '%s\n' "$issue_line" | sed -n 's/.*gh issue list --repo "\([^"]*\)".*/\1/p')"
search_line="$(printf '%s\n' "$body" | grep -- '--search ')"
search_str="$(printf '%s\n' "$search_line" | cut -d"'" -f2)"
sel_line="$(printf '%s\n' "$body" | grep 'argjson ms')"
sel_jq_full="$(printf '%s\n' "$sel_line" | cut -d"'" -f2)"
if [ -z "$ms_api_path" ] || [ -z "$ms_jq" ] || [ -z "$issue_repo_path" ] || [ -z "$search_str" ] || [ -z "$sel_jq_full" ]; then
  dieblind "could not parse nightly.sh's queue predicate -- it changed shape"
fi
list_jq="${sel_jq_full% | length}"

ms_api_path="${ms_api_path//\$\{repo\}/$REPO}"
issue_repo_path="${issue_repo_path//\$\{repo\}/$REPO}"

ms_open="$("$GH" api "$ms_api_path" --jq "$ms_jq" 2>/dev/null)"
[ -n "$ms_open" ] || dieblind "cannot read hf7y-estate/$REPO's open milestones"

if [ "$issue_ms" = null ]; then
  in_ms=false
else
  in_ms="$(printf '%s' "$ms_open" | jq --argjson m "$issue_ms" 'any(.[]; . == $m)')"
fi

not_run() { # <reason>
  printf 'WILL NOT RUN -- hf7y-estate/%s#%s: %s\n' "$REPO" "$N" "$1"
  force_line
  exit "$EXIT_FINDING"
}

# The order below is the one #80 specifies: repo, then the milestone
# questions, then the labels, then closed -- not the order nightly.sh's
# own `--state open` + `--search` happen to apply the same checks in.
[ "$ms_open" != '[]' ] || not_run "no open milestone in hf7y-estate/$REPO"
[ "$in_ms" = true ] || not_run "issue not in an open milestone"
case "$labels" in *needs-host*) not_run "needs-host" ;; esac
case "$labels" in *needs-human*) not_run "needs-human" ;; esac
[ "$state" = OPEN ] || not_run "closed"

# RUNS. There is no rank to report any more (realisateur#1420 deleted the
# `first` label) -- just confirm the dispatcher's own queue listing (which reads
# at most 200 open issues, as nightly.sh does) actually contains this issue.
queue_json="$("$GH" issue list --repo "$issue_repo_path" --state open --limit 200 \
    --search "$search_str" --json number,title,milestone 2>/dev/null \
  | jq --argjson ms "$ms_open" "$list_jq")"
[ -n "$queue_json" ] || dieblind "cannot read hf7y-estate/$REPO's queue"

in_queue="$(printf '%s' "$queue_json" | jq --argjson n "$N" 'any(.[]; .number == $n)')"
[ "$in_queue" = true ] || dieblind "hf7y-estate/$REPO#$N passed every check but the dispatchers own queue listing (capped at 200 open issues) does not contain it"

total="$(printf '%s' "$queue_json" | jq 'length')"
plural=s; [ "$total" -eq 1 ] && plural=''
printf 'RUNS -- hf7y-estate/%s#%s is in the queue (%s runnable issue%s)\n' "$REPO" "$N" "$total" "$plural"
exit "$EXIT_OK"
