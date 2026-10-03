#!/usr/bin/env bash
#
# Usage: bin/tests/credential-wire-check.test.sh   (exit 0 = all pass)

set -uo pipefail
# shellcheck source=bin/tests/lib/harness.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/credential-wire-check.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT not executable"; exit 1; }

harness_tmp

# A stub PATH so live git/demande are never touched. STUB/demande logs its
# call and answers per $STUB_DEMANDE_RC / $STUB_DEMANDE_OUT.
STUB="$T/stub"; mkdir -p "$STUB"
cat > "$STUB/demande" <<'DEMANDE'
#!/usr/bin/env bash
LOG="${STUB_DEMANDE_LOG:-/dev/null}"
printf '%s\n' "$*" >> "$LOG"
case "${STUB_DEMANDE_RC:-0}" in
  0) printf '%s\n' "${STUB_DEMANDE_OUT:-deadbeef}"; exit 0 ;;
  *) exit "${STUB_DEMANDE_RC}" ;;
esac
DEMANDE
chmod +x "$STUB/demande"

run() { # run --account NAME [--helper VALUE] -- via the script's own flags
  RUN_OUT="$(PATH="$STUB:$PATH" "$SCRIPT" "$@" 2>&1)"; RUN_RC=$?
}

echo "credential-wire-check.test.sh"

section "A. app: no finding"
run --account acct-app --helper 'selfdev-gh-app.sh --wire --repos acct-app --credential'
rc  "A1 wired to the App exits 0"                0 "$RUN_RC"
has "A2 and says ok"                             "$RUN_OUT" "ok, wired to the App"

section "B. none: no credential at all"
LOG="$T/log-b"; : > "$LOG"
STUB_DEMANDE_LOG="$LOG" run --account acct-none --helper ''
rc  "B1 no helper exits 1"                       1 "$RUN_RC"
has "B2 FLAGs the finding"                       "$RUN_OUT" "no git credential helper"
has "B3 escalates via demande"                   "$RUN_OUT" "ESCALATED via demande"
has "B4 names the ticket from demande's stdout"  "$RUN_OUT" "deadbeef"
has "B5 the demande call carries the account"    "$(cat "$LOG")" "acct-none"
has "B6 ...and the reason"                       "$(cat "$LOG")" "no git credential helper"

section "C. gh: the shared token by its old route"
LOG="$T/log-c"; : > "$LOG"
STUB_DEMANDE_LOG="$LOG" run --account acct-gh --helper '!gh auth git-credential'
rc  "C1 the gh-auth helper exits 1"              1 "$RUN_RC"
has "C2 names the shared gho_ token"             "$RUN_OUT" "shared gho_ token"
has "C3 names the fix"                           "$RUN_OUT" "selfdev-gh-app.sh --wire"
has "C4 still escalates"                         "$RUN_OUT" "ESCALATED via demande"

section "D. multi: more than one helper value is undecidable"
LOG="$T/log-d"; : > "$LOG"
STUB_DEMANDE_LOG="$LOG" run --account acct-multi --helper $'!gh auth git-credential\n!selfdev-gh-app.sh --credential'
rc  "D1 two helper values exits 1"               1 "$RUN_RC"
has "D2 names it undecidable"                    "$RUN_OUT" "MORE THAN ONE value"

section "E. other: an unrecognized helper"
run --account acct-other --helper '!store'
rc  "E1 an unrecognized helper exits 1"          1 "$RUN_RC"
has "E2 names the raw value"                     "$RUN_OUT" "'other'"

section "F. escalation never turns a real finding fatal"
LOG="$T/log-f1"; : > "$LOG"
STUB_DEMANDE_OUT='' STUB_DEMANDE_RC=6 STUB_DEMANDE_LOG="$LOG" \
  run --account acct-blind-relay --helper ''
rc  "F1 a BLIND relay still exits 1, the finding's code, not 6"  1 "$RUN_RC"
has "F2 says the escalation itself was BLIND"    "$RUN_OUT" "ESCALATION BLIND"
has "F3 and still prints the finding to report by hand" "$RUN_OUT" "report by hand"

# A PATH with the coreutils this script needs (grep, printf's builtin needs
# no PATH entry, but the shell itself does) and DELIBERATELY NOT $STUB and
# NOT wherever a real `demande` might be installed on the machine running
# this suite (/usr/local/bin, verbs' own install target) -- this exercises
# "demande is not installed here" for real, and must never reach a live relay.
RUN_OUT="$(PATH="/usr/bin:/bin" "$SCRIPT" --account acct-no-demande --helper '' 2>&1)"; RUN_RC=$?
rc  "F4 demande missing entirely still exits 1, not fatal"  1 "$RUN_RC"
has "F5 says escalation was skipped, names why"  "$RUN_OUT" "ESCALATION SKIPPED"

section "G. the argument contract"
RUN_OUT="$("$SCRIPT" --helper app 2>&1)"; RUN_RC=$?
rc  "G1 no --account is BLIND, not a guess"      6 "$RUN_RC"
has "G2 says so by name"                         "$RUN_OUT" "BLIND"
RUN_OUT="$("$SCRIPT" --account x --not-a-flag 2>&1)"; RUN_RC=$?
rc  "G3 an unknown flag is a usage error"        2 "$RUN_RC"
RUN_OUT="$("$SCRIPT" --account 2>&1)"; RUN_RC=$?
rc  "G4 --account with no value is a usage error" 2 "$RUN_RC"

summary
