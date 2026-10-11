#!/usr/bin/env bash
#
# Usage: bin/tests/dispatch-turn-cap.test.sh   (exit 0 = all pass)

set -uo pipefail
# shellcheck source=bin/tests/lib/harness.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/dispatch-turn-cap.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT not executable"; exit 1; }

harness_tmp

run() {
  RUN_OUT="$("$SCRIPT" "$@" 2>&1)"; RUN_RC=$?
}

echo "dispatch-turn-cap.test.sh"

section "A. the 2026-10-06 night (etalon#118): one pass at 139/150, one finding"
mkdir -p "$T/night-2026-10-06"
cat > "$T/night-2026-10-06/musc-2300.20261006T141650Z.log" <<'EOF'
=== 20261006T141650Z agent pass: hf7y-estate/musc-2300 (turns=150) ===
=== checkout: /work/musc-2300   log: /srv/agent/musc-2300.20261006T141650Z.log ===
  > Bash git status
=== result: success  turns=139  cost=$4.5678
=== 2026-10-06T14:55:12Z container exited (rc=0) ===
EOF
cat > "$T/night-2026-10-06/senechal.20261006T020000Z.log" <<'EOF'
=== 20261006T020000Z agent pass: hf7y-estate/senechal (turns=150) ===
  > Bash git status
=== result: success  turns=41  cost=$0.9012
=== 2026-10-06T02:30:00Z container exited (rc=0) ===
EOF
run --logs "$T/night-2026-10-06"
rc  "A1 one pass at or over 90% exits 1"        1 "$RUN_RC"
has "A2 says 1 of 2 measurable"                 "$RUN_OUT" "1 of 2 measurable"
has "A3 names musc-2300's log"                  "$RUN_OUT" "musc-2300.20261006T141650Z.log"
has "A4 shows its turn count"                   "$RUN_OUT" "139/150 turns"
hasnt "A5 does not name the comfortable pass"   "$RUN_OUT" "senechal.20261006T020000Z.log"
has "A6 FLAGs and names 'too large'"            "$RUN_OUT" "FLAG [dispatch-turn-cap]"
has "A7 names the split instruction"            "$RUN_OUT" "must split, not continue"

section "B. a comfortable night: nothing near the cap"
mkdir -p "$T/clean"
cat > "$T/clean/senechal.20261007T020000Z.log" <<'EOF'
=== 20261007T020000Z agent pass: hf7y-estate/senechal (turns=150) ===
=== result: success  turns=12  cost=$0.3
EOF
cat > "$T/clean/etalon.20261007T030000Z.log" <<'EOF'
=== 20261007T030000Z agent pass: hf7y-estate/etalon (turns=150) ===
=== result: success  turns=89  cost=$1.1
EOF
run --logs "$T/clean"
rc  "B1 nothing near the cap exits 0"           0 "$RUN_RC"
has "B2 says 0 of 2 measurable"                 "$RUN_OUT" "0 of 2 measurable"
has "B3 says ok"                                "$RUN_OUT" "ok -- every measurable pass"

section "C. exactly at 90% is still a finding (boundary, not just over)"
mkdir -p "$T/boundary"
cat > "$T/boundary/wtul.20261007T040000Z.log" <<'EOF'
=== 20261007T040000Z agent pass: hf7y-estate/wtul (turns=100) ===
=== result: success  turns=90  cost=$2.0
EOF
run --logs "$T/boundary"
rc  "C1 exactly 90% exits 1"                    1 "$RUN_RC"
has "C2 names it"                               "$RUN_OUT" "wtul.20261007T040000Z.log"

section "D. an incomplete log carries nothing measurable and is skipped, not guessed"
mkdir -p "$T/incomplete"
cat > "$T/incomplete/crashed.20261007T050000Z.log" <<'EOF'
=== 20261007T050000Z agent pass: hf7y-estate/crashed (turns=150) ===
  > Bash git status
=== 2026-10-07T05:10:00Z container exited (rc=1) ===
EOF
cat > "$T/incomplete/senechal.20261007T060000Z.log" <<'EOF'
=== 20261007T060000Z agent pass: hf7y-estate/senechal (turns=150) ===
=== result: success  turns=5  cost=$0.1
EOF
run --logs "$T/incomplete"
rc  "D1 the crashed log is skipped, the clean one counted" 0 "$RUN_RC"
has "D2 only one of two logs was measurable"    "$RUN_OUT" "0 of 1 measurable"
hasnt "D3 never names the unmeasurable log"     "$RUN_OUT" "crashed.20261007T050000Z.log"

section "E. it never passes silently"
run --nope
rc  "E1 an unknown flag is a usage error"       2 "$RUN_RC"
run
rc  "E2 --logs is required"                     2 "$RUN_RC"
run --logs "$T/does-not-exist"
rc  "E3 a missing directory is BLIND"           6 "$RUN_RC"
has "E4 and says so"                            "$RUN_OUT" "BLIND"
mkdir -p "$T/empty"
run --logs "$T/empty"
rc  "E5 a directory with no logs is BLIND"      6 "$RUN_RC"
has "E6 not a clean pass it never read"         "$RUN_OUT" "BLIND"
mkdir -p "$T/all-incomplete"
cat > "$T/all-incomplete/x.20261007T070000Z.log" <<'EOF'
no header, no result line, nothing to measure
EOF
run --logs "$T/all-incomplete"
rc  "E7 logs present but none measurable is BLIND, not a clean pass" 6 "$RUN_RC"
has "E8 and says so"                            "$RUN_OUT" "BLIND"

summary
