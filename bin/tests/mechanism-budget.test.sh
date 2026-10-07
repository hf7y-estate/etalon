#!/usr/bin/env bash
#
# Usage: bin/tests/mechanism-budget.test.sh   (exit 0 = all pass)

set -uo pipefail
# shellcheck source=bin/tests/lib/harness.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/mechanism-budget.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT not executable"; exit 1; }

harness_tmp

G() { git -c user.email=t@test -c user.name=T -C "$T/$1" "${@:2}"; }

newrepo() {
  mkdir -p "$T/$1"
  G "$1" init -q -b main
  printf 'notes\n' > "$T/$1/README.md"
  G "$1" add -A
  G "$1" commit -qm base
}

  mech() {
  mkdir -p "$(dirname "$T/$1/$2")"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$T/$1/$2"
  chmod +x "$T/$1/$2"
}

# A script invoked by a workflow job step: write it, and add a run: line
# in $3 (a workflow file under .github/workflows/) naming its path.
mech_called() {
  mech "$1" "$2"
  mkdir -p "$T/$1/.github/workflows"
  printf 'name: %s\non: [push]\njobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n      - run: bash %s\n' \
    "$3" "$2" > "$T/$1/.github/workflows/$3.yml"
}

# A script nobody's workflow names directly, only run via the
# bin/tests/*.test.sh glob loop -- the #116 case.
mech_glob_only() {
  mkdir -p "$(dirname "$T/$1/$2")"
  printf '#!/usr/bin/env bash\n# RUNNER: .github/workflows/ci.yml\nexit 0\n' > "$T/$1/$2"
  chmod +x "$T/$1/$2"
}

# A script declared to run by hand, with a reason.
mech_by_hand() {
  mkdir -p "$(dirname "$T/$1/$2")"
  printf '#!/usr/bin/env bash\n# RUNNER: by hand -- %s\nexit 0\n' "$3" > "$T/$1/$2"
  chmod +x "$T/$1/$2"
}

run() {
  local r="$1"; shift
  RUN_OUT="$(MECHANISM_BUDGET_RATCHET="$T/$r/.mechanism-ratchet" "$SCRIPT" --repo "$T/$r" "$@" 2>&1)"
  RUN_RC=$?
}

echo "mechanism-budget.test.sh"

section "A. what counts as a mechanism"
newrepo counting
mech counting bin/tool.sh
mech counting bin/other.sh
mech counting bin/tests/tool.test.sh
mkdir -p "$T/counting/.github/workflows"
printf 'name: ci\non: [push]\njobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n      - run: bash bin/tool.sh\n      - run: bash bin/other.sh\n' \
  > "$T/counting/.github/workflows/ci.yml"
printf 'x\n' > "$T/counting/lib.sh"
G counting add -A; G counting commit -qm mechanisms
run counting --accept
has "A1 two called scripts plus one workflow"  "$RUN_OUT" "baseline is now 3 mechanism(s)"
G counting add -A; G counting commit -qm ratchet
run counting
rc  "A2 at the baseline it exits 0"           0 "$RUN_RC"
has "A3 and reports the delta"                "$RUN_OUT" "delta +0"

section "B. a net add cannot pass"
mech_by_hand counting bin/new.sh "cuts the release; no job step calls it"
G counting add -A; G counting commit -qm add
run counting
rc  "B1 one more mechanism exits 1"           1 "$RUN_RC"
has "B2 and FLAGs the budget"                 "$RUN_OUT" "FLAG [mechanism-budget]"
has "B3 naming the delta"                     "$RUN_OUT" "delta +1"
has "B4 and listing what it counted"          "$RUN_OUT" "bin/new.sh"

section "C. the ratchet only falls"
run counting --accept
rc  "C1 --accept REFUSES to raise it"         1 "$RUN_RC"
has "C2 and says so"                          "$RUN_OUT" "REFUSED"
eq  "C3 leaving the baseline untouched"       "$(grep -v '^#' "$T/counting/.mechanism-ratchet" | tr -d '[:space:]')" "3"
G counting rm -q "bin/new.sh" "bin/other.sh"
G counting commit -qm retire
run counting
rc  "C4 two retirements pass"                 0 "$RUN_RC"
has "C5 and invite a lower baseline"          "$RUN_OUT" "run --accept to lock it in"
run counting --accept
has "C6 which --accept records"               "$RUN_OUT" "baseline is now 2 mechanism(s)"

section "D. it never passes silently"
run counting --nope
rc  "D1 an unknown flag is a usage error"     2 "$RUN_RC"
RUN_OUT="$("$SCRIPT" --repo "$T/does-not-exist" 2>&1)"; RUN_RC=$?
rc  "D2 a missing repo is BLIND"              6 "$RUN_RC"
mkdir -p "$T/notrepo"
RUN_OUT="$("$SCRIPT" --repo "$T/notrepo" 2>&1)"; RUN_RC=$?
rc  "D3 a non-repository is BLIND"            6 "$RUN_RC"
has "D4 and says it could not look"           "$RUN_OUT" "BLIND"
newrepo noratchet
run noratchet
rc  "D5 a missing baseline is BLIND, not a pass" 6 "$RUN_RC"
has "D6 and says how to seed it"              "$RUN_OUT" "--accept"

section "E. a caller is required, not just the executable bit"
newrepo callers
run callers --accept
has "E0 a plain repo with no scripts baselines at 0" "$RUN_OUT" "baseline is now 0 mechanism(s)"
mech callers bin/plain.sh
mech_glob_only callers bin/glob-runner.sh
mech_by_hand callers bin/manual.sh "cuts the release; no job step calls it"
mech_called callers bin/direct.sh ci
mech callers bin/tests/glob-runner.test.sh
G callers add -A; G callers commit -qm scripts
run callers
rc  "E1 three real mechanisms over a zero baseline"    1 "$RUN_RC"
has "E2 delta is +3, not +4"                            "$RUN_OUT" "delta +3"
has "E3 the by-hand script is charged"                  "$RUN_OUT" "bin/manual.sh"
has "E4 the directly-invoked script is charged"         "$RUN_OUT" "bin/direct.sh"
has "E5 the workflow that invokes it is charged too"    "$RUN_OUT" ".github/workflows/ci.yml"
hasnt "E6 an uncalled executable is not charged"        "$RUN_OUT" "bin/plain.sh"
hasnt "E7 a script run only via the test glob is not charged -- #116" "$RUN_OUT" "bin/glob-runner.sh"

summary
