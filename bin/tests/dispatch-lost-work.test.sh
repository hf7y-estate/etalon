#!/usr/bin/env bash
#
# Usage: bin/tests/dispatch-lost-work.test.sh   (exit 0 = all pass)

set -uo pipefail
# shellcheck source=bin/tests/lib/harness.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/dispatch-lost-work.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT not executable"; exit 1; }

harness_tmp

run() {
  RUN_OUT="$("$SCRIPT" "$@" 2>&1)"; RUN_RC=$?
}

echo "dispatch-lost-work.test.sh"

section "A. the 2026-10-06 night (etalon#118): two lost-work logs, one finding"
mkdir -p "$T/night-2026-10-06"
cat > "$T/night-2026-10-06/realisateur.fix-token-refresh-1504.log" <<'EOF'
[dispatch] starting pass on hf7y-estate/realisateur
turn 40: committed fix-token-refresh-1504
=== SALVAGE FAILED: could not push fix-token-refresh-1504 -- branch is the only copy
=== result: success
EOF
cat > "$T/night-2026-10-06/realisateur.milestone-quality-survey.log" <<'EOF'
[dispatch] starting pass on hf7y-estate/realisateur
turn 118: committed milestone-quality-survey
=== SALVAGE FAILED: could not push milestone-quality-survey -- branch is the only copy
=== result: success
EOF
cat > "$T/night-2026-10-06/senechal.clean-pass.log" <<'EOF'
[dispatch] starting pass on hf7y-estate/senechal
turn 5: nothing to land
=== result: success
EOF
cat > "$T/night-2026-10-06/wtul.unrelated-failure.log" <<'EOF'
[dispatch] starting pass on hf7y-estate/wtul
API Error: No response from API
pass exited 1
EOF
run --logs "$T/night-2026-10-06"
rc  "A1 two lost-work logs exits 1"                   1 "$RUN_RC"
has "A2 says 2 of 4 logs"                             "$RUN_OUT" "2 of 4 log(s)"
has "A3 names the fix-token-refresh-1504 log"         "$RUN_OUT" "realisateur.fix-token-refresh-1504.log"
has "A4 names the milestone-quality-survey log"       "$RUN_OUT" "realisateur.milestone-quality-survey.log"
hasnt "A5 does not name the clean pass"               "$RUN_OUT" "senechal.clean-pass.log"
hasnt "A6 does not name the unrelated non-success exit" "$RUN_OUT" "wtul.unrelated-failure.log"
has "A7 FLAGs the lost work"                          "$RUN_OUT" "FLAG [dispatch-lost-work]"
has "A8 names what the act owes"                      "$RUN_OUT" "comment naming"

section "B. a failed push, not a failed salvage, is the same lie"
mkdir -p "$T/push-fail"
cat > "$T/push-fail/bibliothecaire.rejected.log" <<'EOF'
[dispatch] starting pass on hf7y-estate/bibliothecaire
To https://github.com/hf7y-estate/bibliothecaire
 ! [rejected]        fix-123 -> fix-123 (fetch first)
error: failed to push some refs
=== result: success
EOF
run --logs "$T/push-fail"
rc  "B1 a failed push alongside success exits 1"      1 "$RUN_RC"
has "B2 names the log"                                "$RUN_OUT" "bibliothecaire.rejected.log"

section "C. a clean night: no finding"
mkdir -p "$T/clean"
cat > "$T/clean/senechal.20261007T020000Z.log" <<'EOF'
[dispatch] starting pass on hf7y-estate/senechal
=== result: success
EOF
cat > "$T/clean/etalon.20261007T030000Z.log" <<'EOF'
[dispatch] starting pass on hf7y-estate/etalon
turn 12: pass exited 1, no commits made
EOF
run --logs "$T/clean"
rc  "C1 no lost work exits 0"                         0 "$RUN_RC"
has "C2 says 0 of 2"                                  "$RUN_OUT" "0 of 2 log(s)"
has "C3 says ok"                                      "$RUN_OUT" "ok -- no log claims success"

section "D. a failed salvage with no success claim is not this check's finding"
mkdir -p "$T/honest-failure"
cat > "$T/honest-failure/realisateur.honest.log" <<'EOF'
[dispatch] starting pass on hf7y-estate/realisateur
=== SALVAGE FAILED: could not push honest-branch
=== result: failure
EOF
run --logs "$T/honest-failure"
rc  "D1 an honestly-reported failure exits 0"         0 "$RUN_RC"
has "D2 says 0 of 1"                                  "$RUN_OUT" "0 of 1 log(s)"

section "E. it never passes silently"
run --nope
rc  "E1 an unknown flag is a usage error"             2 "$RUN_RC"
run
rc  "E2 --logs is required"                           2 "$RUN_RC"
run --logs "$T/does-not-exist"
rc  "E3 a missing directory is BLIND"                 6 "$RUN_RC"
has "E4 and says so"                                  "$RUN_OUT" "BLIND"
mkdir -p "$T/empty"
run --logs "$T/empty"
rc  "E5 a directory with no logs is BLIND"            6 "$RUN_RC"
has "E6 not a clean pass it never read"               "$RUN_OUT" "BLIND"

summary
