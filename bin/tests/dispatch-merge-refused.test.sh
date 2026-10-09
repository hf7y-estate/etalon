#!/usr/bin/env bash
#
# Usage: bin/tests/dispatch-merge-refused.test.sh   (exit 0 = all pass)

set -uo pipefail
# shellcheck source=bin/tests/lib/harness.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/dispatch-merge-refused.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT not executable"; exit 1; }

harness_tmp

run() {
  RUN_OUT="$("$SCRIPT" "$@" 2>&1)"; RUN_RC=$?
}

echo "dispatch-merge-refused.test.sh"

section "A. the 2026-10-06 night (etalon#118): one merge-carry refusal"
mkdir -p "$T/night-2026-10-06"
cat > "$T/night-2026-10-06/realisateur.20261006T073804Z.log" <<'EOF'
[dispatch] starting pass on hf7y-estate/realisateur
=== the previous pass's PRs on hf7y-estate/realisateur ===
  FAILED   #1112 -- merge refused, kept for the next pass
=== result: success
EOF
cat > "$T/night-2026-10-06/wtul.20261006T104500Z.log" <<'EOF'
[dispatch] starting pass on hf7y-estate/wtul
=== the previous pass's PRs on hf7y-estate/wtul ===
  MERGED   #90
=== result: success
EOF
run --logs "$T/night-2026-10-06"
rc  "A1 one merge-carry refusal exits 1"         1 "$RUN_RC"
has "A2 says 1 of 2 logs"                        "$RUN_OUT" "1 merge-carry refusal(s) of 2 log(s)"
has "A3 names the log and the PR"                "$RUN_OUT" "realisateur.20261006T073804Z.log #1112"
hasnt "A4 does not name the unrelated merge"     "$RUN_OUT" "wtul"
has "A5 FLAGs it, naming the requeue boundary"   "$RUN_OUT" "FLAG [dispatch-merge-refused]"
has "A6 and names the dispatcher-side act"       "$RUN_OUT" "dispatcher-side"

section "B. a clean night: no refusal is not a finding"
mkdir -p "$T/clean"
cat > "$T/clean/senechal.20261007T020000Z.log" <<'EOF'
[dispatch] starting pass on hf7y-estate/senechal
=== the previous pass's PRs on hf7y-estate/senechal ===
  MERGED   #5
=== result: success
EOF
cat > "$T/clean/etalon.20261007T030000Z.log" <<'EOF'
[dispatch] starting pass on hf7y-estate/etalon
=== result: success
EOF
run --logs "$T/clean"
rc  "B1 zero refusals exits 0"                   0 "$RUN_RC"
has "B2 says 0 of 2"                             "$RUN_OUT" "0 merge-carry refusal(s) of 2 log(s)"
has "B3 says ok"                                 "$RUN_OUT" "ok -- no merge-carry refusal"

section "C. an Actions-disabled refusal still flags, note and all"
mkdir -p "$T/noted"
cat > "$T/noted/crt.20261006T120000Z.log" <<'EOF'
[dispatch] starting pass on hf7y-estate/crt
=== the previous pass's PRs on hf7y-estate/crt ===
  FAILED   #42 -- merge refused, kept for the next pass -- Actions disabled on hf7y-estate/crt, check records ignored
EOF
run --logs "$T/noted"
rc  "C1 the noted variant still flags"           1 "$RUN_RC"
has "C2 names the PR"                            "$RUN_OUT" "crt.20261006T120000Z.log #42"

section "D. two refusals in one night, both named"
mkdir -p "$T/two"
cat > "$T/two/a.20261006T010000Z.log" <<'EOF'
  FAILED   #1 -- merge refused, kept for the next pass
EOF
cat > "$T/two/b.20261006T020000Z.log" <<'EOF'
  FAILED   #2 -- merge refused, kept for the next pass
EOF
run --logs "$T/two"
rc  "D1 both named exits 1"                      1 "$RUN_RC"
has "D2 names the first"                         "$RUN_OUT" "a.20261006T010000Z.log #1"
has "D3 names the second"                        "$RUN_OUT" "b.20261006T020000Z.log #2"

section "E. it never passes silently"
run --nope
rc  "E1 an unknown flag is a usage error"        2 "$RUN_RC"
run
rc  "E2 --logs is required"                      2 "$RUN_RC"
run --logs "$T/does-not-exist"
rc  "E3 a missing directory is BLIND"            6 "$RUN_RC"
has "E4 and says so"                             "$RUN_OUT" "BLIND"
mkdir -p "$T/empty"
run --logs "$T/empty"
rc  "E5 a directory with no logs is BLIND"       6 "$RUN_RC"
has "E6 not a clean night it never read"         "$RUN_OUT" "BLIND"

summary
