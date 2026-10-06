#!/usr/bin/env bash
#
# Usage: bin/tests/unreached-audit.test.sh   (exit 0 = all pass)

set -uo pipefail
# shellcheck source=bin/tests/lib/harness.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/unreached-audit.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT not executable"; exit 1; }

harness_tmp

G() { git -c user.email=t@test -c user.name=T -C "$T/$1" "${@:2}"; }

newrepo() {
  mkdir -p "$T/$1"
  G "$1" init -q -b main
}

put() { # <repo> <path> <content...>
  local r="$1" p="$2"
  shift 2
  mkdir -p "$(dirname "$T/$r/$p")"
  printf '%s\n' "$@" > "$T/$r/$p"
}

putx() { put "$@"; chmod +x "$T/$1/$2"; }

commit() { G "$1" add -A; G "$1" commit -qm snap; }

run() {
  local r="$1"; shift
  RUN_OUT="$("$SCRIPT" --repo "$T/$r" "$@" 2>&1)"
  RUN_RC=$?
}

echo "unreached-audit.test.sh"

section "A. a direct entry-point reference reaches a file"
newrepo proj
putx proj agent/entry.sh '#!/usr/bin/env bash' 'bin/reached.sh'
putx proj bin/reached.sh '#!/usr/bin/env bash' 'echo reached'
putx proj bin/orphan.sh '#!/usr/bin/env bash' 'echo orphan'
commit proj
run proj
rc  "A1 one orphan exits FINDING (1)"           1 "$RUN_RC"
has "A2 the entry-named file is not flagged"    "$RUN_OUT" "1 unreached"
has "A3 and the orphan is named, with its line count" "$RUN_OUT" "2  bin/orphan.sh"

section "B. reachability follows calls transitively"
newrepo chain
putx chain agent/entry.sh '#!/usr/bin/env bash' 'bin/first.sh'
putx chain bin/first.sh '#!/usr/bin/env bash' 'source bin/lib/second.sh'
put  chain bin/lib/second.sh '#!/usr/bin/env bash' 'echo deep'
commit chain
run chain
rc  "B1 entry -> first -> second all reached -- exit OK" 0 "$RUN_RC"
has "B2 says so"                                "$RUN_OUT" "ok -- every file"

section "C. a workflow is an entry point too"
newrepo wf
mkdir -p "$T/wf/.github/workflows"
put wf .github/workflows/ci.yml 'name: ci' 'run: bash bin/fromworkflow.sh'
putx wf bin/fromworkflow.sh '#!/usr/bin/env bash' 'echo hi'
putx wf bin/orphan.sh '#!/usr/bin/env bash' 'echo bye'
commit wf
run wf
rc  "C1 the workflow-named script is reached, the other is not" 1 "$RUN_RC"
has "C2 only the orphan is flagged"             "$RUN_OUT" "bin/orphan.sh"
hasnt "C3 the workflow-named script is not flagged" "$RUN_OUT" "fromworkflow.sh are reached by no"

section "D. documentation mentioning a filename is not a call"
newrepo docs
putx docs agent/entry.sh '#!/usr/bin/env bash' 'echo entry, see README.md'
put  docs README.md 'See bin/orphan.sh for details.'
putx docs bin/orphan.sh '#!/usr/bin/env bash' 'echo orphan'
commit docs
run docs
rc  "D1 a README mention does not reach the file it names" 1 "$RUN_RC"
has "D2 the file is still flagged unreached"    "$RUN_OUT" "bin/orphan.sh"

section "E. a test file is not an entry point and not a caller"
newrepo tst
putx tst agent/entry.sh '#!/usr/bin/env bash' 'echo entry'
putx tst bin/orphan.sh '#!/usr/bin/env bash' 'echo orphan'
put  tst bin/tests/orphan.test.sh 'bin/orphan.sh'
commit tst
run tst
rc  "E1 a reference only from a test still counts unreached" 1 "$RUN_RC"
has "E2 and the test itself is not graded"      "$RUN_OUT" "1 file(s) in bin/"

section "F. --dir audits a different subtree"
newrepo other
putx other agent/entry.sh '#!/usr/bin/env bash' 'hooks/used.sh'
putx other hooks/used.sh '#!/usr/bin/env bash' 'echo used'
putx other hooks/orphan.sh '#!/usr/bin/env bash' 'echo orphan'
commit other
run other --dir hooks
rc  "F1 the named subtree is graded instead of bin/" 1 "$RUN_RC"
has "F2 naming its own orphan"                  "$RUN_OUT" "hooks/orphan.sh"

section "G. it never passes silently"
run proj --nope
rc  "G1 an unknown flag is a usage error"       2 "$RUN_RC"
RUN_OUT="$("$SCRIPT" --repo "$T/does-not-exist" 2>&1)"; RUN_RC=$?
rc  "G2 a missing repo is BLIND"                6 "$RUN_RC"
mkdir -p "$T/notrepo"
RUN_OUT="$("$SCRIPT" --repo "$T/notrepo" 2>&1)"; RUN_RC=$?
rc  "G3 a non-repository is BLIND"              6 "$RUN_RC"
has "G4 and says it could not look"             "$RUN_OUT" "BLIND"
newrepo nodir
put nodir README.md 'nothing here'
commit nodir
RUN_OUT="$("$SCRIPT" --repo "$T/nodir" 2>&1)"; RUN_RC=$?
rc  "G5 no bin/ at all is BLIND"                6 "$RUN_RC"
newrepo noentry
putx noentry bin/orphan.sh '#!/usr/bin/env bash' 'echo orphan'
commit noentry
RUN_OUT="$("$SCRIPT" --repo "$T/noentry" 2>&1)"; RUN_RC=$?
rc  "G6 no agent/ and no workflow is BLIND"     6 "$RUN_RC"
has "G7 and says there is no entry point"       "$RUN_OUT" "no committed entry point"

summary
