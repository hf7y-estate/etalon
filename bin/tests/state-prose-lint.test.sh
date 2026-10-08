#!/usr/bin/env bash
#
# Usage: bin/tests/state-prose-lint.test.sh   (exit 0 = all pass)

set -uo pipefail
# shellcheck source=bin/tests/lib/harness.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/state-prose-lint.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT not executable"; exit 1; }

harness_tmp

G() { git -c user.email=t@test -c user.name=T -C "$T/$1" "${@:2}"; }

newrepo() {
  mkdir -p "$T/$1"
  G "$1" init -q -b main
  printf '#!/usr/bin/env bash\necho base\n' > "$T/$1/base.sh"
  G "$1" add -A
  G "$1" commit -qm base
}

run() {
  local r="$1"; shift
  RUN_OUT="$(cd "$T/$r" && STATE_PROSE_RATCHET="$T/$r/.state-ratchet" "$SCRIPT" "$@" 2>&1)"
  RUN_RC=$?
}

echo "state-prose-lint.test.sh"

section "A. a clean tree"
newrepo clean
printf '# The mechanism refuses to write outside its own repo.\nexit 0\n' > "$T/clean/tool.sh"
G clean add -A; G clean commit -qm tool
run clean --accept
rc  "A1 --accept seeds a baseline"                0 "$RUN_RC"
has "A2 and says what it recorded"                "$RUN_OUT" "baseline is now 0 line(s)"
G clean add -A; G clean commit -qm ratchet
run clean
rc  "A3 a clean tree exits 0"                     0 "$RUN_RC"
has "A4 and states how many lines were considered" "$RUN_OUT" "considered"
hasnt "A5 raising no FLAG"                        "$RUN_OUT" "FLAG ["

section "B. state prose is found"
newrepo stateful
printf '# probed 2026-08-13, four accounts stamped unknown\nexit 0\n' > "$T/stateful/probe.sh"
printf 'The bashified branch declares two verbs today.\n' > "$T/stateful/NOTES.md"
G stateful add -A; G stateful commit -qm state
run stateful --accept
has "B1 the baseline counts them"                 "$RUN_OUT" "baseline is now 2 line(s)"
G stateful add -A; G stateful commit -qm ratchet
run stateful
rc  "B2 at the baseline it exits 0"               0 "$RUN_RC"
has "B3 the dated observation is named"           "$RUN_OUT" "[date]"
has "B4 the count is named"                       "$RUN_OUT" "[count]"
has "B5 with file and line"                       "$RUN_OUT" "probe.sh:1:"

section "C. an invariant is a rule, not a state description"
newrepo invariant
printf '# Exactly one copy exists, by construction; two copies would be two versions.\n# Each account must hold at most three keys.\nexit 0\n' > "$T/invariant/rule.sh"
G invariant add -A; G invariant commit -qm rule
run invariant --accept
has "C1 no invariant is counted"                  "$RUN_OUT" "baseline is now 0 line(s)"
G invariant add -A; G invariant commit -qm ratchet
run invariant
rc  "C2 and the tree passes"                      0 "$RUN_RC"

section "D. the ratchet only falls"
newrepo growth
printf '# nothing to see\nexit 0\n' > "$T/growth/a.sh"
G growth add -A; G growth commit -qm a
run growth --accept
G growth add -A; G growth commit -qm ratchet
printf '# probed 2026-08-13, four accounts stamped unknown\nexit 0\n' > "$T/growth/b.sh"
G growth add -A; G growth commit -qm grew
run growth
rc  "D1 a tree over the baseline exits 1"         1 "$RUN_RC"
has "D2 and names the ratchet"                    "$RUN_OUT" "FLAG [state-prose]"
run growth --accept
rc  "D3 --accept REFUSES to raise it"             1 "$RUN_RC"
has "D4 and says so"                              "$RUN_OUT" "REFUSED"
eq  "D5 leaving the baseline untouched"           "$(grep -v '^#' "$T/growth/.state-ratchet" | tr -d '[:space:]')" "0"

section "E. it never passes silently"
run growth --nope
rc  "E1 an unknown flag is a usage error"         2 "$RUN_RC"
mkdir -p "$T/notrepo"
RUN_OUT="$(cd "$T/notrepo" && "$SCRIPT" 2>&1)"; RUN_RC=$?
rc  "E2 outside a repository it exits BLIND"      6 "$RUN_RC"
has "E3 and says it could not look"               "$RUN_OUT" "BLIND"
newrepo noratchet
run noratchet
rc  "E4 a missing baseline is BLIND, not a pass"  6 "$RUN_RC"
has "E5 and says how to seed it"                  "$RUN_OUT" "--accept"

section "F. it does not flag its own source"
newrepo selfscan
mkdir -p "$T/selfscan/bin"
cp "$SCRIPT" "$(dirname "$SCRIPT")/mechanism-budget.sh" "$T/selfscan/bin/"
G selfscan add -A; G selfscan commit -qm copied
run selfscan --accept
has "F1 the two guards contribute nothing"        "$RUN_OUT" "baseline is now 0 line(s)"

section "G. --causal reads TEXT, not a tree -- etalon#20"
causal() { RUN_OUT="$("$SCRIPT" --causal <<<"$1" 2>&1)"; RUN_RC=$?; }

causal 'Parking the fleet is why the verb build cut froze.

No witness attached here, just the claim.'
rc  "G1 an unwitnessed causal claim exits 1"      1 "$RUN_RC"
has "G2 and quotes the claim"                     "$RUN_OUT" "UNWITNESSED: Parking the fleet"
has "G3 report-only, says so"                     "$RUN_OUT" "does not deny on its own"

causal 'Parking the fleet is why the verb build cut froze.

Disproving command, in full:

    gh run list --repo hf7y/verbs --limit 6'
rc  "G4 a witness 2 paragraphs away clears it"    0 "$RUN_RC"
hasnt "G5 no FLAG"                                "$RUN_OUT" "FLAG ["

causal 'It failed because of `bad_flag.sh:42`, confirmed by running it.'
rc  "G6 a same-paragraph backtick witness clears it" 0 "$RUN_RC"

causal 'It is why the build failed, see https://github.com/hf7y/verbs/actions/runs/1'
rc  "G7 a run URL witness clears it"              0 "$RUN_RC"

causal 'Parking the fleet is why the verb build cut froze.

unrelated filler one.

unrelated filler two.

    gh run list --repo hf7y/verbs --limit 6'
rc  "G8 a witness 3 paragraphs away still flags"  1 "$RUN_RC"

causal 'Nothing causal here, just a status update.'
rc  "G9 no causal connective exits 0"             0 "$RUN_RC"
has "G10 and says zero were found"                "$RUN_OUT" "0 unwitnessed causal claim(s)"

causal ''
rc  "G11 empty stdin exits 0, not BLIND"          0 "$RUN_RC"

RUN_OUT="$(cd "$T/notrepo" && "$SCRIPT" --causal </dev/null 2>&1)"; RUN_RC=$?
rc  "G12 --causal needs no git repository at all" 0 "$RUN_RC"

section "H. an extensionless shebang file is not skipped -- etalon#24"
newrepo extensionless
printf '#!/usr/bin/env bash\n# probed 2026-08-13, four accounts stamped unknown\nexit 0\n' > "$T/extensionless/ROSTER"
G extensionless add -A; G extensionless commit -qm roster
run extensionless --accept
has "H1 the extensionless file is scanned"        "$RUN_OUT" "baseline is now 1 line(s)"
G extensionless add -A; G extensionless commit -qm ratchet
run extensionless
has "H2 and the finding names it"                 "$RUN_OUT" "ROSTER:2:"
printf '#!/usr/bin/env python3\n# ten accounts enrolled today\nexit 0\n' > "$T/extensionless/other-roster"
G extensionless add -A; G extensionless commit -qm grew
run extensionless
rc  "H3 a python shebang is sniffed too"          1 "$RUN_RC"
has "H4 both files now counted"                   "$RUN_OUT" "other-roster:2:"
printf 'no shebang, just a plain extensionless file\n' > "$T/extensionless/binary-blob"
G extensionless add -A; G extensionless commit -qm blob
run extensionless
hasnt "H5 a non-shebang extensionless file is still skipped" "$RUN_OUT" "binary-blob"

section "I. a stop word exempts the counted phrase, not the line -- etalon#4"
newrepo stopword
printf '# main had gained 235 lines since it was cut\nexit 0\n' > "$T/stopword/drift.sh"
G stopword add -A; G stopword commit -qm drift
run stopword --accept
has "I1 a stop word elsewhere no longer hides the count" "$RUN_OUT" "baseline is now 1 line(s)"
G stopword add -A; G stopword commit -qm ratchet
run stopword
has "I2 the count is still named"                 "$RUN_OUT" "[count]"
printf '# 2 is less than 3, and the 3 of us agree\nexit 0\n' > "$T/stopword/drift.sh"
G stopword add -A; G stopword commit -qm clear
run stopword
rc  "I3 the counted phrase itself being a stop word still clears it" 0 "$RUN_RC"
hasnt "I4 no FLAG"                                "$RUN_OUT" "FLAG ["

summary
