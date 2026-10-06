#!/usr/bin/env bash
#
# Usage: bin/tests/thermostat-veto.test.sh   (exit 0 = all pass)
#
# No network: gh is a fixture-fed fake on PATH. FIXTURES points at
# pr-<N>.json (full gh-pr-view JSON, shaped like a real `gh pr view
# --json state,mergedAt,files,closingIssuesReferences,statusCheckRollup`
# response) and issue-<N>.body (the raw text `gh issue view --jq .body`
# would print). A missing fixture simulates gh failing to read a PR/issue
# (network, auth, 404) -- the BLIND case.

set -uo pipefail
# shellcheck source=bin/tests/lib/harness.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/thermostat-veto.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT not executable"; exit 1; }
FIXTURE_LOG="$(cd "$(dirname "$0")" && pwd)/fixtures/thermostat-veto/sample-agent.log"

harness_tmp

mkdir -p "$T/fixtures" "$T/bin"

cat > "$T/bin/gh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
cmd="$1"; sub="$2"; num="$3"
case "$cmd/$sub" in
  pr/view)
    f="$FIXTURES/pr-$num.json"
    [ -f "$f" ] || exit 1
    cat "$f"
    ;;
  issue/view)
    f="$FIXTURES/issue-$num.body"
    [ -f "$f" ] || exit 1
    cat "$f"
    ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$T/bin/gh"

pr_fixture() { # <num> <state> <checks-json> <files-json> <issues-json>
  cat > "$T/fixtures/pr-$1.json" <<EOF
{"state":"$2","mergedAt":"2026-10-01T00:00:00Z","statusCheckRollup":$3,"files":$4,"closingIssuesReferences":$5}
EOF
}

issue_fixture() { # <num> <body-file>
  cp "$2" "$T/fixtures/issue-$1.body"
}

issue_ref() { # <num> -- closingIssuesReferences JSON pointing at issue <num>
  printf '[{"repository":{"owner":{"login":"hf7y-estate"},"name":"etalon"},"number":%s}]' "$1"
}

OK_CHECKS='[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}]'
NO_CHECKS='[]'
NONPROSE_FILES='[{"path":"bin/tool.sh","additions":5,"deletions":1}]'
PROSE_FILES='[{"path":"README.md","additions":5,"deletions":1}]'
NOOP_FILES='[{"path":"bin/tool.sh","additions":0,"deletions":0}]'
NO_ISSUE='[]'

printf '## Done when\n\nA command exists that prints VETO or no veto.\n' > "$T/donewhen.body"
printf 'Just a description, no acceptance condition stated anywhere.\n' > "$T/nodonewhen.body"

run() {
  local pr="$1"; shift
  RUN_OUT="$(PATH="$T/bin:$PATH" FIXTURES="$T/fixtures" "$SCRIPT" --repo hf7y-estate/etalon --pr "$pr" "$@" 2>&1)"
  RUN_RC=$?
}

echo "thermostat-veto.test.sh"

section "A. a clean merged PR: no veto"
pr_fixture 1 MERGED "$OK_CHECKS" "$NONPROSE_FILES" "$(issue_ref 1)"
issue_fixture 1 "$T/donewhen.body"
run 1
rc  "A1 passes all three checks"              0 "$RUN_RC"
eq  "A2 and prints no veto"                   "$RUN_OUT" "no veto"

section "B. tests never ran -- silence, not a verdict"
pr_fixture 2 MERGED "$NO_CHECKS" "$NONPROSE_FILES" "$(issue_ref 2)"
issue_fixture 2 "$T/donewhen.body"
run 2
rc  "B1 VETOes with exit 1"                   1 "$RUN_RC"
has "B2 naming the silence"                   "$RUN_OUT" "VETO tests did not run"

section "C. only comments/prose changed"
pr_fixture 3 MERGED "$OK_CHECKS" "$PROSE_FILES" "$(issue_ref 3)"
issue_fixture 3 "$T/donewhen.body"
run 3
rc  "C1 VETOes with exit 1"                   1 "$RUN_RC"
has "C2 naming the prose-only touch"          "$RUN_OUT" "VETO PR touches only comments/prose"

section "D. the PR closes no issue"
pr_fixture 4 MERGED "$OK_CHECKS" "$NONPROSE_FILES" "$NO_ISSUE"
run 4
rc  "D1 VETOes with exit 1"                   1 "$RUN_RC"
has "D2 naming the missing link"              "$RUN_OUT" "VETO PR closes no issue"

section "E. the closed issue states no done-when"
pr_fixture 5 MERGED "$OK_CHECKS" "$NONPROSE_FILES" "$(issue_ref 5)"
issue_fixture 5 "$T/nodonewhen.body"
run 5
rc  "E1 VETOes with exit 1"                   1 "$RUN_RC"
has "E2 naming the missing condition"         "$RUN_OUT" "state no done-when/acceptance condition"

section "F. the issue has a done-when, but the diff is a no-op"
pr_fixture 6 MERGED "$OK_CHECKS" "$NOOP_FILES" "$(issue_ref 6)"
issue_fixture 6 "$T/donewhen.body"
run 6
rc  "F1 VETOes with exit 1"                   1 "$RUN_RC"
has "F2 naming the no-op"                     "$RUN_OUT" "VETO PR's diff is a no-op"

section "G. CI is silent, but the pass's own log recorded a real result"
pr_fixture 101 MERGED "$NO_CHECKS" "$NONPROSE_FILES" "$(issue_ref 101)"
issue_fixture 101 "$T/donewhen.body"
run 101 --log "$FIXTURE_LOG"
rc  "G1 pr=101's tests=pass in the log satisfies the check" 0 "$RUN_RC"
eq  "G2 so the rest clears to no veto"          "$RUN_OUT" "no veto"
pr_fixture 102 MERGED "$NO_CHECKS" "$NONPROSE_FILES" "$(issue_ref 102)"
issue_fixture 102 "$T/donewhen.body"
run 102 --log "$FIXTURE_LOG"
rc  "G3 tests=fail also counts as ran, not silence" 0 "$RUN_RC"
pr_fixture 103 MERGED "$NO_CHECKS" "$NONPROSE_FILES" "$(issue_ref 103)"
issue_fixture 103 "$T/donewhen.body"
run 103 --log "$FIXTURE_LOG"
rc  "G4 a result line with no tests= field is still silence" 1 "$RUN_RC"
has "G5 and VETOes on it"                       "$RUN_OUT" "VETO tests did not run"

section "H. more than one check fails -- the first is reported, the rest listed"
pr_fixture 8 MERGED "$NO_CHECKS" "$PROSE_FILES" "$NO_ISSUE"
run 8
rc  "H1 VETOes with exit 1"                    1 "$RUN_RC"
has "H2 the first reason leads"                "$RUN_OUT" "VETO tests did not run"
has "H3 the others are listed too"             "$RUN_OUT" "also vetoed on"
has "H4 including the prose-only touch"        "$RUN_OUT" "touches only comments/prose"

section "I. BLIND, never reported as a pass or a veto"
run 999
rc  "I1 an unreadable PR is BLIND"             6 "$RUN_RC"
has "I2 and says so"                           "$RUN_OUT" "BLIND"
pr_fixture 9 MERGED "$OK_CHECKS" "$NONPROSE_FILES" "$(issue_ref 9999)"
run 9
rc  "I3 an unreadable linked issue is BLIND too" 6 "$RUN_RC"
has "I4 not silently scored as clean"          "$RUN_OUT" "BLIND"

section "J. it never passes silently on bad input"
RUN_OUT="$(PATH="$T/bin:$PATH" FIXTURES="$T/fixtures" "$SCRIPT" --pr 1 2>&1)"; RUN_RC=$?
rc  "J1 a missing --repo is a usage error"     2 "$RUN_RC"
RUN_OUT="$(PATH="$T/bin:$PATH" FIXTURES="$T/fixtures" "$SCRIPT" --repo x/y --pr abc 2>&1)"; RUN_RC=$?
rc  "J2 a non-numeric --pr is a usage error"   2 "$RUN_RC"
RUN_OUT="$(PATH="$T/bin:$PATH" FIXTURES="$T/fixtures" "$SCRIPT" --repo x/y --pr 1 --nope 2>&1)"; RUN_RC=$?
rc  "J3 an unknown flag is a usage error"      2 "$RUN_RC"
RUN_OUT="$(PATH="$T/bin:$PATH" FIXTURES="$T/fixtures" "$SCRIPT" --repo x/y --pr 1 --log "$T/no-such-file" 2>&1)"; RUN_RC=$?
rc  "J4 a missing --log file is BLIND"         6 "$RUN_RC"

summary
