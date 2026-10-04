#!/usr/bin/env bash
#
# Usage: bin/tests/will-it-run.test.sh   (exit 0 = all pass)
#
# No real network or gh: WILL_IT_RUN_GH points the script at a stub that
# answers from fixtures under $T/stub, built below. The fixtures for
# agent/nightly.sh and agent/run-agent.sh are real excerpts (the function
# and lines will-it-run.sh's extraction depends on), not invented shapes.

set -uo pipefail
# shellcheck source=bin/tests/lib/harness.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/will-it-run.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT not executable"; exit 1; }

harness_tmp
STUB="$T/stub"
mkdir -p "$STUB"

cat > "$STUB/run-agent.sh" <<'EOF'
#!/usr/bin/env bash
repo="${1:?usage: run-agent.sh <repo> [max_turns] [issue]}"
turns="${2:-150}"
issue="${3:-}"
EOF

cat > "$STUB/nightly.sh" <<'EOF'
#!/usr/bin/env bash
turns="${TURNS:-150}"
queue_count() {
  local repo="$1" ms n
  ms="$(gh api "repos/hf7y-estate/${repo}/milestones?state=open&per_page=100" --jq '[.[].number]' 2>/dev/null)" \
    || { echo ERR; return; }
  n="$(gh issue list --repo "hf7y-estate/${repo}" --state open --limit 200 \
        --search '-label:needs-host -label:needs-human' --json milestone 2>/dev/null \
      | jq --argjson ms "$ms" '[.[] | select(.milestone and (.milestone.number as $m | $ms|index($m)))] | length')" \
    || { echo ERR; return; }
  echo "$n"
}
EOF

printf '# comment\nproj\ncrt\n' > "$STUB/agent-repos"
printf 'proj\ncrt\nchezz\nproj2\n' > "$STUB/org-repos.txt"

printf '[5]\n' > "$STUB/milestones-proj.json"
printf '[]\n'  > "$STUB/milestones-proj2.json"

issue() { # <repo> <n> <state> <ms-or-null> <label-or-empty>
  local repo="$1" n="$2" state="$3" ms="$4" label="$5" labels_json='[]'
  [ -n "$label" ] && labels_json="[{\"id\":\"L1\",\"name\":\"$label\"}]"
  local ms_json=null
  [ "$ms" != null ] && ms_json="{\"number\":$ms,\"title\":\"m\",\"dueOn\":null}"
  printf '{"number":%s,"state":"%s","title":"t","labels":%s,"milestone":%s}\n' \
    "$n" "$state" "$labels_json" "$ms_json" > "$STUB/issue-$repo-$n.json"
}

issue proj  9  OPEN   5    ''
issue proj  12 OPEN   5    ''
issue proj  20 CLOSED 5    ''
issue proj  30 OPEN   5    needs-host
issue proj  40 OPEN   null ''
issue proj  60 OPEN   5    needs-human
issue proj2 50 OPEN   null ''

# The raw (pre milestone-select, post search-filter) queue listing for proj:
# #40 carries no milestone and must be dropped by will-it-run.sh's own list_jq,
# proving the extracted predicate -- not a hand count -- did the filtering.
cat > "$STUB/queue-proj.json" <<'EOF'
[
  {"number":9,"title":"a","milestone":{"number":5,"title":"m","dueOn":null}},
  {"number":12,"title":"c","milestone":{"number":5,"title":"m","dueOn":null}},
  {"number":40,"title":"d","milestone":null}
]
EOF

cat > "$STUB/gh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
case "$1" in
  api)
    path="$2"
    case "$path" in
      repos/hf7y-estate/realisateur/contents/agent/run-agent.sh) base64 -w0 < "$STUB/run-agent.sh" ;;
      repos/hf7y-estate/realisateur/contents/agent/repos)        base64 -w0 < "$STUB/agent-repos" ;;
      repos/hf7y-estate/realisateur/contents/agent/nightly.sh)   base64 -w0 < "$STUB/nightly.sh" ;;
      repos/hf7y-estate/*/milestones\?*)
        repo="${path#repos/hf7y-estate/}"; repo="${repo%%/milestones*}"
        cat "$STUB/milestones-$repo.json" 2>/dev/null || exit 1
        ;;
      *) echo "stub-gh: unhandled api path: $path" >&2; exit 1 ;;
    esac
    ;;
  repo)
    [ "$2" = list ] && cat "$STUB/org-repos.txt" || { echo "stub-gh: unhandled repo subcmd" >&2; exit 1; }
    ;;
  issue)
    case "$2" in
      view)
        n="$3"; repo="${5#hf7y-estate/}"
        cat "$STUB/issue-$repo-$n.json" 2>/dev/null || exit 1
        ;;
      list)
        repo="${4#hf7y-estate/}"
        cat "$STUB/queue-$repo.json" 2>/dev/null || exit 1
        ;;
      *) echo "stub-gh: unhandled issue subcmd: $2" >&2; exit 1 ;;
    esac
    ;;
  *) echo "stub-gh: unhandled command: $1" >&2; exit 1 ;;
esac
EOF
chmod +x "$STUB/gh"

export STUB
export WILL_IT_RUN_GH="$STUB/gh"

run() {
  RUN_OUT="$("$SCRIPT" "$@" 2>&1)"
  RUN_RC=$?
}

echo "will-it-run.test.sh"

section "A. RUNS -- no rank, just queue membership"
run proj 9
rc  "A1 a runnable issue exits 0"                  0 "$RUN_RC"
has "A2 and says RUNS"                             "$RUN_OUT" "RUNS"
has "A3 and is in the queue"                       "$RUN_OUT" "is in the queue"
run proj 12
rc  "A4 another runnable issue exits 0"            0 "$RUN_RC"
has "A5 the dropped no-milestone issue does not inflate the count" "$RUN_OUT" "2 runnable issues"

section "B. an issue in no open milestone"
run proj 40
rc  "B1 exits 1"                                   1 "$RUN_RC"
has "B2 says WILL NOT RUN"                         "$RUN_OUT" "WILL NOT RUN"
has "B3 names the reason"                          "$RUN_OUT" "issue not in an open milestone"
has "B4 and prints the forcing command"            "$RUN_OUT" "ssh dexter '/srv/agent/run-agent.sh proj 150 40'"

section "C. needs-host and needs-human"
run proj 30
rc  "C1 needs-host exits 1"                        1 "$RUN_RC"
has "C2 names needs-host"                          "$RUN_OUT" "needs-host"
run proj 60
rc  "C3 needs-human exits 1"                        1 "$RUN_RC"
has "C4 names needs-human"                         "$RUN_OUT" "needs-human"

section "D. a closed issue"
run proj 20
rc  "D1 exits 1"                                   1 "$RUN_RC"
has "D2 names closed"                              "$RUN_OUT" "closed"

section "E. a repo absent from both agent/repos and the org"
run ghost 1
rc  "E1 exits 1"                                   1 "$RUN_RC"
has "E2 says not dispatched"                       "$RUN_OUT" "not dispatched"
has "E3 still prints the forcing command"          "$RUN_OUT" "ssh dexter '/srv/agent/run-agent.sh ghost 150 1'"

section "F. a repo with no open milestone at all"
run proj2 50
rc  "F1 exits 1"                                   1 "$RUN_RC"
has "F2 names the repo-wide reason"                "$RUN_OUT" "no open milestone in hf7y-estate/proj2"

section "G. usage and BLIND"
run proj
rc  "G1 wrong argument count is a usage error"     2 "$RUN_RC"
run proj abc
rc  "G2 a non-numeric issue is a usage error"      2 "$RUN_RC"
run proj 999
rc  "G3 an issue gh cannot read is BLIND"          6 "$RUN_RC"
has "G4 and says so"                               "$RUN_OUT" "BLIND"

summary
