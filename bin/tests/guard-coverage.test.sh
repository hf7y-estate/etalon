#!/usr/bin/env bash
#
# Usage: bin/tests/guard-coverage.test.sh   (exit 0 = all pass)

set -uo pipefail
# shellcheck source=bin/tests/lib/harness.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/guard-coverage.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT not executable"; exit 1; }

harness_tmp

echo "guard-coverage.test.sh"

# A fake `gh` that answers exactly the three calls this tool makes:
#   api repos/OWNER/REPO/contents/.github/workflows
#   api repos/OWNER/REPO/contents/.github/workflows/<name>
#   api orgs/<org>/repos
# FAKE_GH_* env vars route each to a fixture file; a repo not listed in
# FAKE_GH_WORKFLOWS_<key> 404s, the same as a real repo with no
# .github/workflows directory.
cat > "$T/fake-gh" <<'EOF'
#!/usr/bin/env bash
# args: api <path> --paginate
path="$2"
case "$path" in
  orgs/*/repos)
    [ -n "${FAKE_GH_ORG_REPOS:-}" ] && { cat "$FAKE_GH_ORG_REPOS"; exit 0; }
    echo '{"message":"Not Found","documentation_url":"x","status":"404"}' >&2
    echo 'gh: Not Found (HTTP 404)' >&2
    exit 1
    ;;
  repos/*/contents/.github/workflows)
    repo="${path#repos/}"; repo="${repo%/contents/.github/workflows}"
    key="FAKE_GH_WORKFLOWS_$(printf '%s' "$repo" | tr '/-' '__')"
    val="${!key:-}"
    if [ -n "$val" ]; then cat "$val"; exit 0; fi
    echo '{"message":"Not Found","documentation_url":"x","status":"404"}' >&2
    echo 'gh: Not Found (HTTP 404)' >&2
    exit 1
    ;;
  repos/*/contents/.github/workflows/*)
    rest="${path#repos/}"
    repo="${rest%%/contents/.github/workflows/*}"
    name="${rest##*/contents/.github/workflows/}"
    key="FAKE_GH_FILE_$(printf '%s/%s' "$repo" "$name" | tr '/.-' '___')"
    val="${!key:-}"
    if [ -n "$val" ]; then cat "$val"; exit 0; fi
    echo '{"message":"Not Found","documentation_url":"x","status":"404"}' >&2
    echo 'gh: Not Found (HTTP 404)' >&2
    exit 1
    ;;
  *)
    echo "fake-gh: unhandled path: $path" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$T/fake-gh"

run() { # <args...> -- all FAKE_GH_* already exported by the caller
  RUN_OUT="$(GUARD_COVERAGE_GH="$T/fake-gh" "$SCRIPT" "$@" 2>&1)"
  RUN_RC=$?
}

workflow_list() { # <json-file> <name>...
  local f="$1"; shift
  { printf '['; first=1
    for n in "$@"; do
      [ "$first" -eq 1 ] || printf ','
      printf '{"name":"%s","type":"file"}' "$n"
      first=0
    done
    printf ']'; } > "$f"
}

b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

file_json() { # <out-file> <raw-content>
  printf '{"content":"%s","encoding":"base64"}' "$(b64 "$2")" > "$1"
}

section "A. a repo calling the guard"
workflow_list "$T/a-wf.json" prose.yml
file_json "$T/a-prose.json" 'uses: hf7y/etalon/.github/workflows/guard.yml@main'
FAKE_GH_WORKFLOWS_hf7y_estate_bib="$T/a-wf.json" \
FAKE_GH_FILE_hf7y_estate_bib_prose_yml="$T/a-prose.json" \
  run hf7y-estate/bib
rc  "A1 a calling repo exits 0"                 0 "$RUN_RC"
has "A2 and names the workflow"                 "$RUN_OUT" "hf7y-estate/bib calls: prose.yml"
hasnt "A3 no FLAG for a calling repo"           "$RUN_OUT" "FLAG ["

section "B. a repo with no .github/workflows directory at all -- the wavebucks case"
run media-arts-collective/wavebucks
rc  "B1 a 404 on the workflows dir is a FINDING, not BLIND" 1 "$RUN_RC"
has "B2 and says it calls none"                 "$RUN_OUT" "calls none of etalon's guard workflows"
has "B3 the FLAG names the repo"                "$RUN_OUT" "FLAG ["
has "B4 and the repo is listed"                  "$RUN_OUT" "media-arts-collective/wavebucks"

section "C. a repo whose workflows never mention etalon"
workflow_list "$T/c-wf.json" tests.yml
file_json "$T/c-tests.json" 'name: tests
on: [push]'
FAKE_GH_WORKFLOWS_hf7y_estate_scheduler="$T/c-wf.json" \
FAKE_GH_FILE_hf7y_estate_scheduler_tests_yml="$T/c-tests.json" \
  run hf7y-estate/scheduler
rc  "C1 a workflow present but silent on etalon still exits 1" 1 "$RUN_RC"
has "C2 reported as calling none"               "$RUN_OUT" "calls none of etalon's guard workflows"

section "D. multiple repos in one run"
FAKE_GH_WORKFLOWS_hf7y_estate_bib="$T/a-wf.json" \
FAKE_GH_FILE_hf7y_estate_bib_prose_yml="$T/a-prose.json" \
  run hf7y-estate/bib media-arts-collective/wavebucks
rc  "D1 exits 1 when at least one of several calls none" 1 "$RUN_RC"
has "D2 the calling repo is still reported"     "$RUN_OUT" "hf7y-estate/bib calls: prose.yml"
has "D3 the FLAG counts 1 of 2"                 "$RUN_OUT" "1 of 2 repo(s)"

section "E. discovery with no argument"
printf '[{"full_name":"hf7y-estate/bib"},{"full_name":"media-arts-collective/wavebucks"}]' > "$T/org.json"
FAKE_GH_ORG_REPOS="$T/org.json" \
FAKE_GH_WORKFLOWS_hf7y_estate_bib="$T/a-wf.json" \
FAKE_GH_FILE_hf7y_estate_bib_prose_yml="$T/a-prose.json" \
  run
rc  "E1 no-argument discovery exits 1 (one of two calls none)" 1 "$RUN_RC"
has "E2 the discovered calling repo is reported" "$RUN_OUT" "hf7y-estate/bib calls: prose.yml"
has "E3 the discovered silent repo is reported"  "$RUN_OUT" "wavebucks calls none"

section "F. API failures that are not a 404 stay BLIND"
RUN_OUT="$(GUARD_COVERAGE_GH="$T/fake-gh" "$SCRIPT" hf7y-estate/unreachable 2>&1)"; RUN_RC=$?
rc  "F1 an unmocked repo (fake-gh's catch-all 404) is a finding" 1 "$RUN_RC"
cat > "$T/fake-gh-down" <<'EOF'
#!/usr/bin/env bash
echo 'gh: connection reset' >&2
exit 1
EOF
chmod +x "$T/fake-gh-down"
RUN_OUT="$(GUARD_COVERAGE_GH="$T/fake-gh-down" "$SCRIPT" hf7y-estate/bib 2>&1)"; RUN_RC=$?
rc  "F2 a non-404 API failure exits BLIND"      6 "$RUN_RC"
has "F3 and says so"                            "$RUN_OUT" "BLIND"

section "G. usage"
RUN_OUT="$("$SCRIPT" not-an-owner-slash-repo 2>&1)"; RUN_RC=$?
rc  "G1 an argument with no / is a usage error" 2 "$RUN_RC"
RUN_OUT="$("$SCRIPT" --bogus 2>&1)"; RUN_RC=$?
rc  "G2 an unknown flag is a usage error"       2 "$RUN_RC"

summary
