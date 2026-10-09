#!/usr/bin/env bash
# guard-coverage.sh -- which estate repos call none of etalon's guards.
# RUNNER: by hand -- this reads OTHER repos over the GitHub API; a live
#   estate-wide scan does not belong in this repo's own pull-request CI, the
#   same reason bin/state-prose-lint.sh --api is not wired into tests.yml
#   either (etalon#142).
# GUARD-TEST: bin/tests/guard-coverage.test.sh
#
# TRAPS: a repo with no .github/workflows directory at all is a 404 from the
# contents API, and that 404 is the finding ("calls none"), not a BLIND --
# collapsing the two would report every un-guarded repo as unreadable instead
# of uncalled. Any OTHER API failure (auth, network, rate limit) stays BLIND:
# a repo this tool could not read must never be counted as passing.

set -uo pipefail

CLI_NAME='guard-coverage.sh'
CLI_SUMMARY="which estate repos call none of etalon's guard workflow(s)?"
CLI_USAGE='  guard-coverage.sh
      discover org hf7y-estate'\''s repos over the API and report, for each,
      which guard workflow(s) it calls
  guard-coverage.sh OWNER/REPO [OWNER/REPO ...]
      report on just the named repo(s) (any owner, not only hf7y-estate --
      this is how the media-arts-collective/wavebucks case is reproduced)'
CLI_FLAGS=''
CLI_EXITS="  0  every repo checked calls at least one of etalon's guard workflows
  1  at least one repo checked calls none
  2  usage error
  6  BLIND: the repo list, or a repo's workflow files, could not be read
     from the API (a missing .github/workflows directory is NOT this --
     it is a finding)"
CLI_POSITIONAL=any
. "$(dirname "${BASH_SOURCE[0]}")/lib/cli-guard.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib/exit-codes.sh"
cli_guard "$@"

die2()    { printf '%s: %s\n' "$CLI_NAME" "$*" >&2; exit "$EXIT_USAGE"; }
dieblind(){ printf '%s: BLIND -- %s\n' "$CLI_NAME" "$*" >&2; exit "$EXIT_BLIND"; }

for a in "$@"; do
  case "$a" in
    */*) ;;
    *) die2 "not an OWNER/REPO: $a" ;;
  esac
done

GH_BIN="${GUARD_COVERAGE_GH:-gh}"
ESTATE_ORG="${GUARD_COVERAGE_ORG:-hf7y-estate}"

# A workflow calls etalon's guard if it names either the pre-move org
# (etalon#110: the live form, `uses: hf7y/etalon/...`) or the post-move one.
CALLS_ETALON='hf7y(-estate)?/etalon'

# Any non-404 failure is BLIND: this tool must never report a repo it could
# not read as passing. A 404 on the workflows directory itself means "no
# workflows at all", which is the finding this tool exists to catch.
#
# The functions below set a GC_* global instead of returning their result
# on stdout for a caller to capture with $(...) -- a command substitution
# forks a subshell, and dieblind's `exit` inside one would kill only that
# subshell, letting the main script read an empty result and carry on as if
# nothing were wrong. Called plainly (never as $(fn ...)), dieblind's exit
# here ends the whole script, which is the point of it.
workflows_of() { # <owner/repo> -> sets GC_NAMES, one file name per line
  local out rc
  out="$("$GH_BIN" api "repos/$1/contents/.github/workflows" --paginate 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    case "$out" in
      *'HTTP 404'*) GC_NAMES=''; return 0 ;;
      *) dieblind "could not read $1's .github/workflows from the API: $out" ;;
    esac
  fi
  GC_NAMES="$(printf '%s' "$out" | jq -r '.[] | select(.type == "file") | .name' 2>/dev/null)" \
    || dieblind "$1's .github/workflows listing was not the JSON array the API promises"
}

content_of() { # <owner/repo> <workflow-file-name> -> sets GC_CONTENT, decoded
  local out rc
  out="$("$GH_BIN" api "repos/$1/contents/.github/workflows/$2" --paginate 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] || dieblind "could not read $1/.github/workflows/$2 from the API: $out"
  GC_CONTENT="$(printf '%s' "$out" | jq -r '.content' 2>/dev/null | base64 -d 2>/dev/null)" \
    || dieblind "$1/.github/workflows/$2 had no readable base64 content"
}

guards_called_by() { # <owner/repo> -> sets GC_CALLED, matching file name(s), one per line
  local name
  workflows_of "$1"
  GC_CALLED=''
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    case "$name" in *.yml|*.yaml) ;; *) continue ;; esac
    content_of "$1" "$name"
    printf '%s' "$GC_CONTENT" | grep -Eq "$CALLS_ETALON" && GC_CALLED="$GC_CALLED$name"$'\n'
  done <<EOF
$GC_NAMES
EOF
}

if [ $# -gt 0 ]; then
  REPOS="$(printf '%s\n' "$@")"
else
  ORG_OUT="$("$GH_BIN" api "orgs/$ESTATE_ORG/repos" --paginate 2>&1)" || dieblind "could not list $ESTATE_ORG's repos from the API: $ORG_OUT"
  REPOS="$(printf '%s' "$ORG_OUT" | jq -r '.[].full_name' 2>/dev/null)" \
    || dieblind "$ESTATE_ORG's repo list was not the JSON array the API promises"
  [ -n "$REPOS" ] || dieblind "$ESTATE_ORG has no repos, or the API returned none -- refusing to report a clean estate I did not read"
fi

checked=0
uncalled=''
while IFS= read -r repo; do
  [ -n "$repo" ] || continue
  checked=$((checked + 1))
  guards_called_by "$repo"
  if [ -n "$GC_CALLED" ]; then
    printf 'guard-coverage -- %s calls: %s\n' "$repo" "$(printf '%s' "$GC_CALLED" | tr '\n' ' ' | sed 's/ $//')"
  else
    printf 'guard-coverage -- %s calls none of etalon'"'"'s guard workflows\n' "$repo"
    uncalled="$uncalled$repo"$'\n'
  fi
done <<EOF
$REPOS
EOF

[ "$checked" -gt 0 ] || dieblind "no repo was checked"

if [ -n "$uncalled" ]; then
  n="$(printf '%s' "$uncalled" | grep -c .)"
  printf '  FLAG [guard-coverage] %d of %d repo(s) call none of etalon'"'"'s guards (etalon#142):\n' \
    "$n" "$checked"
  printf '%s' "$uncalled" | sed 's/^/        /'
  exit "$EXIT_FINDING"
fi
printf '  ok -- all %d repo(s) checked call at least one of etalon'"'"'s guards.\n' "$checked"
exit "$EXIT_OK"
