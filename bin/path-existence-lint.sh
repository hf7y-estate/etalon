#!/usr/bin/env bash
# path-existence-lint.sh -- prose that names a mechanism this tree does not have.
#
# RUNNER: .github/workflows/tests.yml
# GUARD-TEST: bin/tests/path-existence-lint.test.sh
# GATE: a backticked path cited in a tracked .md file, or in a commit message
# this branch adds, must exist in the HEAD tree or the merge-base tree
# (origin/main). Neither means the prose names a script, unit or path that is
# not there -- hf7y/etalon#31, three live instances found in hf7y/crt in one
# session: a commit message describing files a fork reconciliation dropped, a
# doc calling a retired systemd unit "the only working path today", and a
# doc's "still open" list naming services that exist nowhere in that repo.
#
# TRAPS:
#   1. A citation inside a ``` fence records what output ONCE was, not a live
#      claim -- fence lines are stripped before extraction, same rule
#      markdown-cost.sh and state-prose-lint.sh already hold.
#   2. `vault:` citations are a deliberate archive by design and must never
#      be probed -- crt pushes retired prose there instead of deleting it.
#   3. An owner/repo-qualified citation (`hf7y/other-repo/bin/x.sh`) names
#      ANOTHER tree. This guard reads one repo; that citation is out of scope,
#      not stale.
#   4. Without a merge base, "missing from HEAD" cannot be told apart from
#      "this PR deleted it, which is legitimate" -- prose may discuss a file
#      the same PR removes. A miss with no merge base to check is therefore
#      BLIND, never silently a pass and never charged as a finding it cannot
#      support.

set -uo pipefail

CLI_NAME='path-existence-lint.sh'
CLI_SUMMARY='does tracked prose, or a commit message this branch adds, name a path the tree does not have?'
CLI_USAGE='  path-existence-lint.sh   check tracked .md files and new commit messages against the tree'
CLI_FLAGS=''
CLI_EXITS='  0  every cited path exists in the HEAD tree or the merge-base tree
  1  a cited path exists in NEITHER -- the prose names a mechanism that is not there
  6  BLIND: not a repository, the tree or log could not be read, or a cited
     path is missing from HEAD with no merge base to check it against'
CLI_POSITIONAL=none
. "$(dirname "${BASH_SOURCE[0]}")/lib/cli-guard.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib/exit-codes.sh"
cli_guard "$@"

dieblind(){ printf '%s: BLIND -- %s\n' "$CLI_NAME" "$*" >&2; exit "$EXIT_BLIND"; }

git rev-parse --git-dir >/dev/null 2>&1 || dieblind "not inside a git repository"

# --- extraction: backticked spans, fence-stripped -------------------------
# ONE predicate for both sources (tracked .md, commit messages) so a path
# cannot be found in one and missed in the other for no reason.
extract_from_text() { # reads text on stdin -> one backticked span per line
  awk '
    BEGIN { fence = 0 }
    {
      line = $0
      s = line
      sub(/^[ \t]+/, "", s)
      if (s ~ /^```/) { fence = !fence; next }
      if (fence) next
      rest = line
      while ((p = index(rest, "`")) > 0) {
        rest = substr(rest, p + 1)
        q = index(rest, "`")
        if (q == 0) break
        cand = substr(rest, 1, q - 1)
        rest = substr(rest, q + 1)
        if (cand != "") print cand
      }
    }
  '
}

# A trailing :NNN or :NNN-MM is a cited line/range, not part of the path, and
# trailing sentence punctuation rides along when a citation ends a sentence.
clean_candidate() {
  printf '%s' "$1" | sed -E 's/:[0-9]+(-[0-9]+)?$//; s/[.:,;]+$//'
}

# Known shapes only (hf7y/etalon#31): bin/*, tests/*, systemd/*.service,
# *.py, *.sh, *.yml. A bare word with no matching shape is prose, not a
# citation -- matching anything backticked would turn every \`inline code\`
# span into a path claim.
shape_ok() {
  case "$1" in
    bin/*|tests/*)          return 0 ;;
    systemd/*.service)      return 0 ;;
    *.py|*.sh|*.yml)        return 0 ;;
  esac
  return 1
}

excluded_candidate() { # <candidate> -> 0 if out of scope for THIS tree
  case "$1" in
    *vault:*)                 return 0 ;; # a deliberate archive -- never probed
    /*|http://*|https://*)    return 0 ;; # absolute path or URL, not repo-relative
    *'#'*)                    return 0 ;; # an issue/PR ref riding the same span
    hf7y/*|hf7y-estate/*)     return 0 ;; # owner/repo-qualified: names ANOTHER tree
  esac
  return 1
}

# present <candidate> <name-of-NUL-delimited-tree-array> -> 0 if the tree
# holds it exactly, or as the tail of a longer path (a citation without a
# leading directory is not wrong for omitting one).
present() {
  local cand="$1" ref="$2" p
  local -n _tree="$ref"
  for p in "${_tree[@]}"; do
    [ "$p" = "$cand" ] && return 0
    case "$p" in */"$cand") return 0 ;; esac
  done
  return 1
}

mapfile -d '' HEAD_TREE < <(git ls-files -z) || dieblind "cannot list tracked files"
[ "${#HEAD_TREE[@]}" -gt 0 ] || dieblind "no tracked files -- refusing to report a clean tree I did not read"

mapfile -d '' MD_FILES < <(git ls-files -z -- '*.md' '*.markdown') || dieblind "cannot list markdown files"

# source<TAB>candidate, deduplicated by the pair so one citation in two docs
# is not reported twice for the same reason.
RAW=''
for f in "${MD_FILES[@]}"; do
  [ -f "$f" ] || continue
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    RAW+="$f"$'\t'"$c"$'\n'
  done < <(extract_from_text < "$f")
done

# Commit messages THIS BRANCH ADDS. Scanning all of history would re-flag
# every retired path an old commit ever mentioned truthfully; scanning only
# mergebase..HEAD matches what a PR actually introduces. With no merge base
# resolvable yet, the tip commit is still checked -- the common single-commit
# case this guard's own motivating instance (a 40-line message describing
# three absent files) looked exactly like.
MB=''
if git rev-parse --verify -q origin/main >/dev/null 2>&1; then
  MB="$(git merge-base HEAD origin/main 2>/dev/null)" || MB=''
fi

if [ -n "$MB" ]; then
  COMMIT_RANGE="$MB..HEAD"
else
  COMMIT_RANGE='-1 HEAD'
fi
# shellcheck disable=SC2086  # COMMIT_RANGE is a controlled internal value, not user input
SHAS="$(git log --format=%H $COMMIT_RANGE 2>/dev/null)" || dieblind "cannot read the commit log"
while IFS= read -r sha; do
  [ -n "$sha" ] || continue
  short="$(git rev-parse --short "$sha")"
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    RAW+="commit:$short"$'\t'"$c"$'\n'
  done < <(git show -s --format=%B "$sha" | extract_from_text)
done <<EOF
$SHAS
EOF

RAW="$(printf '%s' "$RAW" | sort -u)"

FINDINGS=''
AMBIGUOUS=''
MB_LOADED=0
MB_TREE=()

[ -n "$RAW" ] && while IFS=$'\t' read -r src cand; do
  [ -n "$cand" ] || continue
  cand="$(clean_candidate "$cand")"
  [ -n "$cand" ] || continue
  excluded_candidate "$cand" && continue
  shape_ok "$cand" || continue

  present "$cand" HEAD_TREE && continue

  if [ -z "$MB" ]; then
    AMBIGUOUS+="$src"$'\t'"$cand"$'\n'
    continue
  fi
  if [ "$MB_LOADED" -eq 0 ]; then
    mapfile -d '' MB_TREE < <(git ls-tree -r --name-only -z "$MB" 2>/dev/null) \
      || dieblind "cannot read the merge-base tree at $MB"
    MB_LOADED=1
  fi
  present "$cand" MB_TREE && continue

  FINDINGS+="$src"$'\t'"$cand"$'\n'
done <<EOF
$RAW
EOF

if [ -n "$FINDINGS" ]; then
  printf '%s -- a cited path exists in neither the HEAD tree nor the merge base:\n' "$CLI_NAME" >&2
  printf '%s\n' "$FINDINGS" | grep . | while IFS=$'\t' read -r src cand; do
    printf '  %-40s %s\n' "$src" "$cand" >&2
  done
  printf '  The prose names a script, unit or path that is not there. Fix the\n' >&2
  printf '  citation, or delete the claim.\n' >&2
  exit "$EXIT_FINDING"
fi

if [ -n "$AMBIGUOUS" ]; then
  printf '%s\n' "$AMBIGUOUS" | grep . | while IFS=$'\t' read -r src cand; do
    printf '  %-40s %s\n' "$src" "$cand" >&2
  done
  dieblind "the path(s) above are missing from HEAD and there is no merge base to check whether this branch deleted them. Fetch origin/main."
fi

printf '%s -- ok, every cited path exists in the HEAD tree or the merge base.\n' "$CLI_NAME"
exit "$EXIT_OK"
