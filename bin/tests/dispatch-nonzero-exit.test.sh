#!/usr/bin/env bash
#
# Usage: bin/tests/dispatch-nonzero-exit.test.sh   (exit 0 = all pass)

set -uo pipefail
# shellcheck source=bin/tests/lib/harness.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/dispatch-nonzero-exit.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT not executable"; exit 1; }

harness_tmp

run() {
  RUN_OUT="$(DISPATCH_NONZERO_EXIT_GH="${FAKE_GH:-}" "$SCRIPT" "$@" 2>&1)"; RUN_RC=$?
}

echo "dispatch-nonzero-exit.test.sh"

section "A. the 2026-10-06 night (etalon#118): two non-zero exits, one finding each"
mkdir -p "$T/night-2026-10-06"
cat > "$T/night-2026-10-06/wtul.20261006T083000Z.log" <<'EOF'
[dispatch] starting pass on hf7y-estate/wtul
turn 3: API Error: No response from API
--- hf7y-estate/wtul: pass exited 1 (its own log has the reason)
=== result: success
EOF
cat > "$T/night-2026-10-06/realisateur.20261006T091500Z.log" <<'EOF'
[dispatch] starting pass on hf7y-estate/realisateur
turn 9: API Error: No response from API
run-agent.sh:296: REPORT.md: Permission denied
--- hf7y-estate/realisateur: pass exited 1 (its own log has the reason)
=== result: success
EOF
cat > "$T/night-2026-10-06/senechal.20261006T100000Z.log" <<'EOF'
[dispatch] starting pass on hf7y-estate/senechal
turn 5: nothing to land
=== result: success
EOF
run --logs "$T/night-2026-10-06"
rc  "A1 two non-zero exits exits FINDING"            1 "$RUN_RC"
has "A2 says 2 of 3 logs"                            "$RUN_OUT" "2 of 3 log(s)"
has "A3 names the wtul log and its rc"               "$RUN_OUT" "wtul.20261006T083000Z.log -- pass exited 1"
has "A4 names the realisateur log and its rc"        "$RUN_OUT" "realisateur.20261006T091500Z.log -- pass exited 1"
hasnt "A5 does not name the clean pass"              "$RUN_OUT" "senechal.20261006T100000Z.log --"
has "A6 prints the last lines, the harness crash included" "$RUN_OUT" "REPORT.md: Permission denied"
has "A7 FLAGs it, naming the act it is owed"          "$RUN_OUT" "FLAG [dispatch-nonzero-exit]"
has "A8 says updated not duplicated"                  "$RUN_OUT" "updated on a second occurrence, not"

section "B. a clean night: no finding"
mkdir -p "$T/clean"
cat > "$T/clean/senechal.20261007T020000Z.log" <<'EOF'
[dispatch] starting pass on hf7y-estate/senechal
=== result: success
EOF
run --logs "$T/clean"
rc  "B1 zero non-zero exits exits 0"                  0 "$RUN_RC"
has "B2 says 0 of 1"                                   "$RUN_OUT" "0 of 1 log(s)"
has "B3 says ok"                                       "$RUN_OUT" "ok -- no pass exited non-zero"

section "C. it never passes silently"
RUN_OUT="$("$SCRIPT" 2>&1)"; RUN_RC=$?
rc  "C1 no --logs is a usage error"                    2 "$RUN_RC"

RUN_OUT="$("$SCRIPT" --logs /does/not/exist 2>&1)"; RUN_RC=$?
rc  "C2 a missing directory is BLIND"                  6 "$RUN_RC"

mkdir -p "$T/empty"
RUN_OUT="$("$SCRIPT" --logs "$T/empty" 2>&1)"; RUN_RC=$?
rc  "C3 a directory with no logs is BLIND, not a clean 0" 6 "$RUN_RC"

section "D. --file-issue goes to the repo the pass itself names, keyed so a second run updates rather than duplicates"
cat > "$T/fake-gh" <<'EOF'
#!/usr/bin/env bash
# $1=api, then endpoint/method flags
case "$2" in
  repos/*/issues?state=open*)
    repo="${2#repos/}"; repo="${repo%%/issues*}"
    cat "$FAKE_GH_STATE_DIR/existing.$(printf '%s' "$repo" | tr '/' '_').json" 2>/dev/null || echo '[]'
    ;;
  repos/*/issues/*/comments)
    echo "commented $2" >> "$FAKE_GH_STATE_DIR/calls.log"
    ;;
  repos/*/issues)
    echo "opened $2" >> "$FAKE_GH_STATE_DIR/calls.log"
    printf '{"number": 99}\n'
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$T/fake-gh"
mkdir -p "$T/gh-state"
export FAKE_GH="$T/fake-gh"
export FAKE_GH_STATE_DIR="$T/gh-state"

printf '[]' > "$T/gh-state/existing.hf7y-estate_wtul.json"
printf '[]' > "$T/gh-state/existing.hf7y-estate_realisateur.json"
rm -f "$T/gh-state/calls.log"
run --logs "$T/night-2026-10-06" --file-issue
has "D1 no prior issue: it opens one in the wtul pass's own repo"        "$RUN_OUT" "filed: opened hf7y-estate/wtul#99"
has "D2 and one in the realisateur pass's own repo"                     "$RUN_OUT" "filed: opened hf7y-estate/realisateur#99"
has "D3 the open-issues endpoint was hit for wtul"                      "$(cat "$T/gh-state/calls.log")" "repos/hf7y-estate/wtul/issues"

printf '[{"number": 7, "title": "dispatch-health: pass exited non-zero"}]' > "$T/gh-state/existing.hf7y-estate_wtul.json"
rm -f "$T/gh-state/calls.log"
run --logs "$T/night-2026-10-06" --file-issue
has "D4 an existing issue in that repo is commented on, not reopened"   "$RUN_OUT" "updated hf7y-estate/wtul#7"
has "D5 the comment endpoint was called"                                "$(cat "$T/gh-state/calls.log")" "issues/7/comments"

unset FAKE_GH FAKE_GH_STATE_DIR

summary
