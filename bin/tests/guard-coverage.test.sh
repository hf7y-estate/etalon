#!/usr/bin/env bash
#
# Usage: bin/tests/guard-coverage.test.sh   (exit 0 = all pass)

set -uo pipefail
# shellcheck source=bin/tests/lib/harness.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/guard-coverage.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT not executable"; exit 1; }

harness_tmp

# A stub `gh` that answers `api repos/<owner/repo>[/contents/...]` from
# files dropped under $FAKE_GH_DIR -- a stubbed API response, not a live
# call, same shape as state-prose-lint.test.sh section I.
cat > "$T/fake-gh" <<'EOF'
#!/usr/bin/env bash
path="$2"
case "$path" in
  */contents/.github/workflows/*) f="$FAKE_GH_DIR/file-${path##*/}.json" ;;
  */contents/.github/workflows)   f="$FAKE_GH_DIR/dir.json" ;;
  repos/*)                        f="$FAKE_GH_DIR/repo.json" ;;
  *) exit 1 ;;
esac
if [ -f "$f" ]; then cat "$f"; else printf '{"message":"Not Found","status":"404"}'; exit 1; fi
EOF
chmod +x "$T/fake-gh"

b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

run() {
  local repo="$1"; shift
  RUN_OUT="$(GUARD_COVERAGE_GH="$T/fake-gh" FAKE_GH_DIR="$T/api" "$SCRIPT" "$repo" "$@" 2>&1)"
  RUN_RC=$?
}

echo "guard-coverage.test.sh"

section "A. a repo whose prose.yml calls etalon's guard -- etalon#142's wavebucks counterpart"
rm -rf "$T/api"; mkdir -p "$T/api"
printf '{"full_name":"hf7y-estate/sample"}' > "$T/api/repo.json"
printf '[{"name":"prose.yml","type":"file"},{"name":"tests.yml","type":"file"}]' > "$T/api/dir.json"
PROSE_YML='name: prose
on: [pull_request]
jobs:
  prose:
    uses: hf7y/etalon/.github/workflows/guard.yml@main
'
TESTS_YML='name: tests
on: [pull_request]
jobs:
  suites:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
'
printf '{"content":"%s"}' "$(b64 "$PROSE_YML")" > "$T/api/file-prose.yml.json"
printf '{"content":"%s"}' "$(b64 "$TESTS_YML")" > "$T/api/file-tests.yml.json"

run hf7y-estate/sample
rc  "A1 a repo calling etalon's guard exits 0"    0 "$RUN_RC"
has "A2 and names the calling workflow file"      "$RUN_OUT" "prose.yml"
has "A3 and says how many files it checked"       "$RUN_OUT" "of 2 workflow file(s)"

section "B. a repo with .github/workflows but none of them calling etalon"
rm -rf "$T/api"; mkdir -p "$T/api"
printf '{"full_name":"owner/other"}' > "$T/api/repo.json"
printf '[{"name":"ci.yml","type":"file"}]' > "$T/api/dir.json"
CI_YML='name: ci
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: make test
'
printf '{"content":"%s"}' "$(b64 "$CI_YML")" > "$T/api/file-ci.yml.json"

run owner/other
rc  "B1 a repo calling none of etalon's guards exits 1" 1 "$RUN_RC"
has "B2 and says it calls none"                   "$RUN_OUT" "calls none of etalon's guards"

section "C. a repo with no .github/workflows directory at all -- the wavebucks case"
rm -rf "$T/api"; mkdir -p "$T/api"
printf '{"full_name":"media-arts-collective/wavebucks"}' > "$T/api/repo.json"
# no dir.json -- the stub answers the contents lookup with a 404, same as a
# repo with no .github/ directory at all.

run media-arts-collective/wavebucks
rc  "C1 no workflows directory at all is a FINDING, not BLIND" 1 "$RUN_RC"
has "C2 and it checked zero files"                "$RUN_OUT" "0 workflow file(s) checked"

section "D. an unreadable/nonexistent repo is BLIND"
rm -rf "$T/api"; mkdir -p "$T/api"
# no repo.json at all -- the stub 404s the repo lookup itself.

run owner/does-not-exist
rc  "D1 a repo the API cannot show exits BLIND"   6 "$RUN_RC"
has "D2 and says so"                              "$RUN_OUT" "BLIND"

section "E. usage"
RUN_OUT="$("$SCRIPT" 2>&1)"; RUN_RC=$?
rc  "E1 no argument is a usage error"             2 "$RUN_RC"

RUN_OUT="$("$SCRIPT" not-an-owner-slash-repo 2>&1)"; RUN_RC=$?
rc  "E2 an argument with no owner/repo slash is a usage error" 2 "$RUN_RC"

RUN_OUT="$("$SCRIPT" --help 2>&1)"; RUN_RC=$?
rc  "E3 --help exits 0"                           0 "$RUN_RC"

summary
