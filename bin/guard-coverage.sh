#!/usr/bin/env bash
# guard-coverage.sh -- does an estate repo call any of etalon's guard workflows?
# RUNNER: by hand -- reports one repo's guard coverage over the GitHub API,
#         pointed at a repo as the finding needing it arises; not a CI job
#         of its own (etalon#142)
# GUARD-TEST: bin/tests/guard-coverage.test.sh
#
# TRAPS: a repo with no .github/workflows directory is a FINDING -- it calls
# none -- not BLIND; that absence (no .github/ at all) is exactly the
# wavebucks case this exists to catch (etalon#135, etalon#142). A nonexistent
# or unreadable repo IS blind, and the contents endpoint's 404 looks
# identical for both cases, so the repo itself is read first.

set -uo pipefail

CLI_NAME='guard-coverage.sh'
CLI_SUMMARY="does OWNER/REPO call any of etalon's guard workflows?"
CLI_USAGE='  guard-coverage.sh OWNER/REPO   report which etalon guard workflow(s)
                                 OWNER/REPO calls, read over the GitHub API
                                 with no checkout of OWNER/REPO'
CLI_FLAGS=''
CLI_EXITS='  0  OWNER/REPO calls at least one etalon guard workflow
  1  FINDING: OWNER/REPO calls none
  2  usage error
  6  BLIND: OWNER/REPO is not a readable repository, or the API could not be read'
CLI_POSITIONAL=any
. "$(dirname "${BASH_SOURCE[0]}")/lib/cli-guard.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib/exit-codes.sh"
cli_guard "$@"

die2()    { printf '%s: %s\n' "$CLI_NAME" "$*" >&2; exit "$EXIT_USAGE"; }
dieblind(){ printf '%s: BLIND -- %s\n' "$CLI_NAME" "$*" >&2; exit "$EXIT_BLIND"; }

REPO="${1:-}"
case "$REPO" in
  */*) ;;
  *) die2 "needs an OWNER/REPO argument" ;;
esac
shift
[ $# -eq 0 ] || die2 "unexpected argument: $1"

GH_BIN="${GUARD_COVERAGE_GH:-gh}"

# jq on empty input never makes the filter false/null, so the fetch's own
# exit status is checked before its content, same as state-prose-lint --api.
is_json_object() { [ -n "$1" ] && printf '%s' "$1" | jq -e 'type == "object"' >/dev/null 2>&1; }
is_json_array()  { [ -n "$1" ] && printf '%s' "$1" | jq -e 'type == "array"'  >/dev/null 2>&1; }
is_404() { is_json_object "$1" && printf '%s' "$1" | jq -e '.status == "404"' >/dev/null 2>&1; }

REPO_JSON="$("$GH_BIN" api "repos/$REPO" 2>/dev/null)"; repo_rc=$?
if [ "$repo_rc" -ne 0 ] || ! is_json_object "$REPO_JSON" \
   || ! printf '%s' "$REPO_JSON" | jq -e 'has("full_name")' >/dev/null 2>&1; then
  dieblind "could not read repos/$REPO from the API -- not a repository GitHub will show me"
fi

WORKFLOWS_JSON="$("$GH_BIN" api "repos/$REPO/contents/.github/workflows" --paginate 2>/dev/null)"
wf_rc=$?
if [ "$wf_rc" -ne 0 ]; then
  if is_404 "$WORKFLOWS_JSON"; then
    WORKFLOWS_JSON='[]'  # no .github/workflows at all -- a FINDING, not BLIND
  else
    dieblind "could not read repos/$REPO/.github/workflows from the API"
  fi
elif ! is_json_array "$WORKFLOWS_JSON"; then
  dieblind "repos/$REPO/.github/workflows did not return a file list"
fi

NAMES="$(printf '%s' "$WORKFLOWS_JSON" \
  | jq -r '.[] | select(.type == "file") | select(.name | test("\\.ya?ml$")) | .name')"

CALLS=''
CHECKED=0
while IFS= read -r name; do
  [ -n "$name" ] || continue
  CHECKED=$((CHECKED + 1))
  path=".github/workflows/$name"
  FILE_JSON="$("$GH_BIN" api "repos/$REPO/contents/$path" 2>/dev/null)"; f_rc=$?
  if [ "$f_rc" -ne 0 ] || ! is_json_object "$FILE_JSON" \
     || ! printf '%s' "$FILE_JSON" | jq -e 'has("content")' >/dev/null 2>&1; then
    dieblind "could not read $path from the API"
  fi
  TEXT="$(printf '%s' "$FILE_JSON" | jq -r '.content' | tr -d '\n' | base64 -d 2>/dev/null)"
  if printf '%s' "$TEXT" | grep -qF 'hf7y/etalon'; then
    CALLS="$CALLS$name"$'\n'
  fi
done <<WORKFLOW_NAMES
$NAMES
WORKFLOW_NAMES

CALL_COUNT="$(printf '%s' "$CALLS" | grep -c .)"

if [ "$CALL_COUNT" -gt 0 ]; then
  printf 'guard-coverage %s -- calls etalon via %d of %d workflow file(s):\n' \
    "$REPO" "$CALL_COUNT" "$CHECKED"
  printf '%s' "$CALLS" | sed 's/^/  /'
  exit "$EXIT_OK"
fi

printf "guard-coverage %s -- calls none of etalon's guards (%d workflow file(s) checked)\\n" \
  "$REPO" "$CHECKED"
exit "$EXIT_FINDING"
