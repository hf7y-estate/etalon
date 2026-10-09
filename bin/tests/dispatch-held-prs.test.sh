#!/usr/bin/env bash
#
# Usage: bin/tests/dispatch-held-prs.test.sh   (exit 0 = all pass)

set -uo pipefail
# shellcheck source=bin/tests/lib/harness.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/dispatch-held-prs.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT not executable"; exit 1; }

harness_tmp

echo "dispatch-held-prs.test.sh"

# A fake `gh` that answers exactly the one call this tool makes:
#   pr list --repo OWNER/REPO --state open --limit 200 --json ...
# FAKE_PRS_<key> routes each repo to a fixture file; an unlisted repo is an
# API failure (BLIND), never a quiet empty list.
cat > "$T/fake-gh" <<'EOF'
#!/usr/bin/env bash
# args: pr list --repo OWNER/REPO --state open --limit 200 --json ...
repo=''
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    *) shift ;;
  esac
done
key="FAKE_PRS_$(printf '%s' "$repo" | tr '/-' '__')"
val="${!key:-}"
if [ -n "$val" ]; then cat "$val"; exit 0; fi
echo 'gh: connection reset' >&2
exit 1
EOF
chmod +x "$T/fake-gh"

run() { # <args...> -- caller exports FAKE_PRS_* and DISPATCH_HELD_PRS_NOW first
  RUN_OUT="$(DISPATCH_HELD_PRS_GH="$T/fake-gh" "$SCRIPT" "$@" 2>&1)"
  RUN_RC=$?
}

NOW='1760054400' # 2025-10-10T00:00:00Z, a fixed clock for stable ages

pr() { # <number> <createdAt> <isDraft> <mergeStateStatus>
  printf '{"number":%s,"createdAt":"%s","isDraft":%s,"mergeStateStatus":"%s"}' "$1" "$2" "$3" "$4"
}

section "A. the 2026-10-06 shape (etalon#106/#118): every open PR held"
printf '[%s,%s,%s]' \
  "$(pr 88 '2025-09-28T00:00:00Z' false BLOCKED)" \
  "$(pr 95 '2025-10-01T00:00:00Z' false BLOCKED)" \
  "$(pr 97 '2025-10-05T00:00:00Z' false BLOCKED)" \
  > "$T/a.json"
DISPATCH_HELD_PRS_NOW="$NOW" FAKE_PRS_hf7y_estate_etalon="$T/a.json" \
  run hf7y-estate/etalon
rc  "A1 all-held repo exits 1"                   1 "$RUN_RC"
has "A2 says 3 of 3 held"                        "$RUN_OUT" "3 of 3 open PR(s) held"
has "A3 names PR 88 with its age"                "$RUN_OUT" "#88 (12d old)"
has "A4 names PR 97 with its age"                "$RUN_OUT" "#97 (5d old)"
has "A5 FLAGs the repo"                          "$RUN_OUT" "FLAG [dispatch-held-prs]"
has "A6 cites the repo name in the flag"         "$RUN_OUT" "hf7y-estate/etalon"

section "B. a healthy mix: at least one open PR is not held"
printf '[%s,%s]' \
  "$(pr 10 '2025-10-08T00:00:00Z' false BLOCKED)" \
  "$(pr 11 '2025-10-09T00:00:00Z' false CLEAN)" \
  > "$T/b.json"
DISPATCH_HELD_PRS_NOW="$NOW" FAKE_PRS_hf7y_estate_bib="$T/b.json" \
  run hf7y-estate/bib
rc  "B1 a healthy mix exits 0"                   0 "$RUN_RC"
has "B2 says 1 of 2 held"                        "$RUN_OUT" "1 of 2 open PR(s) held"
has "B3 names the one held PR"                   "$RUN_OUT" "#10"
has "B4 says ok"                                 "$RUN_OUT" "ok -- no checked repo"

section "C. no open PRs at all is not a finding"
printf '[]' > "$T/c.json"
DISPATCH_HELD_PRS_NOW="$NOW" FAKE_PRS_hf7y_estate_quiet="$T/c.json" \
  run hf7y-estate/quiet
rc  "C1 zero open PRs exits 0"                   0 "$RUN_RC"
has "C2 says 0 open PR(s)"                       "$RUN_OUT" "0 open PR(s)"

section "D. a draft PR is never counted as held"
printf '[%s]' "$(pr 20 '2025-10-01T00:00:00Z' true BLOCKED)" > "$T/d.json"
DISPATCH_HELD_PRS_NOW="$NOW" FAKE_PRS_hf7y_estate_drafts="$T/d.json" \
  run hf7y-estate/drafts
rc  "D1 a repo with only a held-looking draft exits 0" 0 "$RUN_RC"
has "D2 says 0 of 1 held"                         "$RUN_OUT" "0 of 1 open PR(s) held"

section "E. multiple repos in one run: only the all-held repo is flagged"
DISPATCH_HELD_PRS_NOW="$NOW" FAKE_PRS_hf7y_estate_etalon="$T/a.json" \
  FAKE_PRS_hf7y_estate_bib="$T/b.json" \
  run hf7y-estate/etalon hf7y-estate/bib
rc  "E1 exits 1 when at least one of several is all-held" 1 "$RUN_RC"
has "E2 the healthy repo is still reported"       "$RUN_OUT" "hf7y-estate/bib: 1 of 2"
has "E3 the FLAG counts 1 repo"                   "$RUN_OUT" "1 repo(s) have EVERY open PR held"
hasnt "E4 the healthy repo is not in the FLAG list" "$RUN_OUT" $'        hf7y-estate/bib\n'

section "F. API failures stay BLIND, never a quiet pass"
RUN_OUT="$(DISPATCH_HELD_PRS_GH="$T/fake-gh" "$SCRIPT" hf7y-estate/unmocked 2>&1)"; RUN_RC=$?
rc  "F1 an unmocked repo exits BLIND"             6 "$RUN_RC"
has "F2 and says so"                              "$RUN_OUT" "BLIND"

section "G. usage"
RUN_OUT="$("$SCRIPT" 2>&1)"; RUN_RC=$?
rc  "G1 no argument is a usage error"             2 "$RUN_RC"
RUN_OUT="$("$SCRIPT" not-an-owner-slash-repo 2>&1)"; RUN_RC=$?
rc  "G2 an argument with no / is a usage error"   2 "$RUN_RC"
RUN_OUT="$("$SCRIPT" --bogus 2>&1)"; RUN_RC=$?
rc  "G3 an unknown flag is a usage error"         2 "$RUN_RC"

summary
