#!/usr/bin/env bash
#
# Usage: bin/tests/dispatch-auth-failures.test.sh   (exit 0 = all pass)

set -uo pipefail
# shellcheck source=bin/tests/lib/harness.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/dispatch-auth-failures.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT not executable"; exit 1; }

harness_tmp

run() {
  RUN_OUT="$("$SCRIPT" "$@" 2>&1)"; RUN_RC=$?
}

echo "dispatch-auth-failures.test.sh"

section "A. the 2026-10-06 night (etalon#118): three auth failures, one finding"
mkdir -p "$T/night-2026-10-06"
cat > "$T/night-2026-10-06/bibliothecaire.20261006T185302Z.log" <<'EOF'
[dispatch] starting pass on hf7y-estate/bibliothecaire
turn 88: HTTP 401: Bad credentials
=== result: success
EOF
cat > "$T/night-2026-10-06/realisateur.20261006T073804Z.log" <<'EOF'
[dispatch] starting pass on hf7y-estate/realisateur
Authentication failed for 'https://github.com/hf7y-estate/realisateur.git/'
=== result: success
EOF
cat > "$T/night-2026-10-06/realisateur.20261006T185255Z.log" <<'EOF'
[dispatch] starting pass on hf7y-estate/realisateur
Authentication failed for 'https://github.com/hf7y-estate/realisateur.git/'
=== result: success
EOF
cat > "$T/night-2026-10-06/wtul.20261006T104500Z.log" <<'EOF'
[dispatch] starting pass on hf7y-estate/wtul
API Error: No response from API
pass exited 1
EOF
run --logs "$T/night-2026-10-06"
rc  "A1 three auth failures exits 1"            1 "$RUN_RC"
has "A2 says 3 of 4 logs"                       "$RUN_OUT" "3 of 4 log(s)"
has "A3 names bibliothecaire's log"             "$RUN_OUT" "bibliothecaire.20261006T185302Z.log"
has "A4 names both of realisateur's logs"       "$RUN_OUT" "realisateur.20261006T073804Z.log"
has "A5 "                                       "$RUN_OUT" "realisateur.20261006T185255Z.log"
hasnt "A6 does not name the unrelated exit"     "$RUN_OUT" "wtul.20261006T104500Z.log"
has "A7 FLAGs the dispatcher, not a repo"        "$RUN_OUT" "FLAG [dispatch-auth-failures]"
has "A8 names the token as the cause"           "$RUN_OUT" "dispatcher"

section "B. a clean night: zero or one is not a finding"
mkdir -p "$T/clean"
cat > "$T/clean/senechal.20261007T020000Z.log" <<'EOF'
[dispatch] starting pass on hf7y-estate/senechal
=== result: success
EOF
cat > "$T/clean/etalon.20261007T030000Z.log" <<'EOF'
[dispatch] starting pass on hf7y-estate/etalon
=== result: success
EOF
run --logs "$T/clean"
rc  "B1 zero auth failures exits 0"             0 "$RUN_RC"
has "B2 says 0 of 2"                            "$RUN_OUT" "0 of 2 log(s)"
has "B3 says ok"                                 "$RUN_OUT" "ok -- at most one"

mkdir -p "$T/one-only"
cat > "$T/one-only/wtul.20261007T040000Z.log" <<'EOF'
HTTP 403: Forbidden
=== result: success
EOF
cat > "$T/one-only/dexter.20261007T050000Z.log" <<'EOF'
=== result: success
EOF
run --logs "$T/one-only"
rc  "B4 exactly one auth failure still exits 0" 0 "$RUN_RC"
has "B5 still names the one it found"           "$RUN_OUT" "wtul.20261007T040000Z.log"

section "C. it never passes silently"
run --nope
rc  "C1 an unknown flag is a usage error"       2 "$RUN_RC"
run
rc  "C2 --logs is required"                     2 "$RUN_RC"
run --logs "$T/does-not-exist"
rc  "C3 a missing directory is BLIND"           6 "$RUN_RC"
has "C4 and says so"                            "$RUN_OUT" "BLIND"
mkdir -p "$T/empty"
run --logs "$T/empty"
rc  "C5 a directory with no logs is BLIND"      6 "$RUN_RC"
has "C6 not a clean pass it never read"         "$RUN_OUT" "BLIND"

summary
