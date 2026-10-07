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
  printf '#!/usr/bin/env bash\n# RUNNER: by hand -- test fixture\nexit 0\n' > "$T/$1/$2"
  chmod +x "$T/$1/$2"
}

  bare() { # <repo> <relpath> -- executable, no workflow caller, no declaration
  mkdir -p "$(dirname "$T/$1/$2")"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$T/$1/$2"
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
printf 'name: ci\n' > "$T/counting/.github/workflows/ci.yml"
printf 'x\n' > "$T/counting/lib.sh"
G counting add -A; G counting commit -qm mechanisms
run counting --accept
has "A1 two scripts plus one workflow"        "$RUN_OUT" "baseline is now 3 mechanism(s)"
G counting add -A; G counting commit -qm ratchet
run counting
rc  "A2 at the baseline it exits 0"           0 "$RUN_RC"
has "A3 and reports the delta"                "$RUN_OUT" "delta +0"

section "B. a net add cannot pass"
mech counting bin/new.sh
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

section "E. a mechanism must have a verifiable caller, not just the executable bit"
newrepo predicate
mkdir -p "$T/predicate/.github/workflows"
printf 'name: ci\njobs:\n  x:\n    steps:\n      - run: bash bin/invoked.sh\n' \
  > "$T/predicate/.github/workflows/ci.yml"
bare predicate bin/invoked.sh
mech predicate bin/declared.sh
bare predicate bin/bare.sh
printf '#!/usr/bin/env bash\n# RUNNER: .github/workflows/tests.yml\nexit 0\n' \
  > "$T/predicate/bin/testrunner-only.sh"
chmod +x "$T/predicate/bin/testrunner-only.sh"
mkdir -p "$T/predicate/bin/tests"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/predicate/bin/tests/testrunner-only.test.sh"
chmod +x "$T/predicate/bin/tests/testrunner-only.test.sh"
G predicate add -A; G predicate commit -qm predicate
run predicate --accept
has "E1 workflow-invoked + by-hand-declared + the workflow file itself" \
                                               "$RUN_OUT" "baseline is now 3 mechanism(s)"
printf '0\n' > "$T/predicate/.mechanism-ratchet"
run predicate
has "E2 over a zero baseline the delta is +3" "$RUN_OUT" "delta +3"
has "E3 a workflow-job-invoked script is charged"   "$RUN_OUT" "bin/invoked.sh"
has "E4 a by-hand declared script is charged"       "$RUN_OUT" "bin/declared.sh"
hasnt "E5 an executable with no caller is not charged" "$RUN_OUT" "bin/bare.sh"
hasnt "E6 a RUNNER pointing only at its own test is not charged" \
                                               "$RUN_OUT" "bin/testrunner-only.sh"

summary
