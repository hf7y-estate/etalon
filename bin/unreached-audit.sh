#!/usr/bin/env bash
# unreached-audit.sh -- starting from a repo's committed entry points, what in
# a directory does nothing reach?
#
# RUNNER: .github/workflows/tests.yml
# GUARD-TEST: bin/tests/unreached-audit.test.sh
#
# Mechanizes realisateur's 2026-10-01 by-hand measurement (hf7y-estate/etalon#81):
# "13 of 54 bin/ scripts named by a live entry point, 3,004 of 13,420 lines" --
# a grep from each entry point against the file list, one level deep. That
# grep admitted its own gap: "misses callers inside the 13". This follows
# calls TRANSITIVELY instead -- a file counts as reached once ANYTHING already
# reached names it, anywhere in the repo, not just inside the graded directory.
#
# ENTRY POINTS, as defined by what's committed: a repo's agent/ scripts and
# its .github/workflows/*.yml. Crontab/systemd units and ~/.claude/settings.json
# are entry points too on a repo a host actually runs, but those live on the
# host, not in any one repo's checkout, and reading them needs a live session
# this container does not have -- out of scope here, same as the parent issue
# scopes it.
#
# THE HEURISTIC: a file is "called" by another if the called file's basename
# appears literally in the caller's content. That overmatches (a comment that
# merely mentions a filename counts as a call) and never undermatches a real
# reference -- so it is biased toward REACHED, never toward UNREACHED. This
# tool's output feeds deletions; a false "reached" costs nothing, a false
# "unreached" costs a file that was load-bearing.
#
# ONE REF ONLY. This reads a single checkout -- whatever ref it was handed --
# so it cannot see a consumer that lives on a DIFFERENT branch of the same
# repo. realisateur's `bashified` is exactly that: bin/lib/zaxon.sh looked
# unreached from `main` (no agent/ script or workflow on `main` names it) and
# is in fact sourced and called by `bin/monkey-watch.sh` on `bashified`.
# This tool's findings are a lead, not a verdict -- confirm a candidate has no
# caller on every branch that actually runs before deleting it.

set -uo pipefail

CLI_NAME='unreached-audit.sh'
CLI_SUMMARY='from committed entry points, what in <dir> does nothing reach?'
CLI_USAGE='  unreached-audit.sh --repo <dir>                audit <dir>/bin against its own entry points
  unreached-audit.sh --repo <dir> --dir <subdir>   audit <subdir> instead of bin'
CLI_FLAGS='--repo --dir'
CLI_EXITS='  0  the repo was read; every file in <dir> is reached by something committed
  1  at least one file in <dir> is reached by nothing committed
  2  usage error
  6  BLIND: not a repository, <dir> does not exist, or it has no committed entry point to start from'
CLI_POSITIONAL=any
. "$(dirname "${BASH_SOURCE[0]}")/lib/cli-guard.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib/exit-codes.sh"
cli_guard "$@"

die2()    { printf '%s: %s\n' "$CLI_NAME" "$*" >&2; exit "$EXIT_USAGE"; }
dieblind(){ printf '%s: BLIND -- %s\n' "$CLI_NAME" "$*" >&2; exit "$EXIT_BLIND"; }

REPO=.
DIR=bin
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) [ $# -ge 2 ] || die2 "--repo needs a directory"; REPO="$2"; shift 2 ;;
    --dir)  [ $# -ge 2 ] || die2 "--dir needs a path"; DIR="$2"; shift 2 ;;
    *) die2 "unexpected argument: $1" ;;
  esac
done
[ -d "$REPO" ] || dieblind "no such directory: $REPO"
REPO="$(cd "$REPO" && pwd)" || dieblind "cannot enter $REPO"
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || dieblind "$REPO is not a git repository"
DIR="${DIR%/}"
[ -d "$REPO/$DIR" ] || dieblind "no $DIR/ in $REPO"

is_test() {
  case "$1" in
    *.test.sh|*_test.sh|test_*|tests/*|*/tests/*|test/*|*/test/*) return 0 ;;
  esac
  return 1
}

# What belongs in the call graph at all -- code and the config that runs it,
# never prose. A README or CLAUDE.md that CATALOGUES the bin/ scripts by name
# is not a caller of them, and letting it act like one is how one doc file
# turns into a bridge that marks everything "reached": a bare documentation
# mention would make a genuinely dead script look live. So documentation is
# excluded from the graph entirely -- not graded, and never a source either.
is_source() { # <mode> <path>
  is_test "$2" && return 1
  case "$2" in *.sh|*.py|*.yml|*.yaml) return 0 ;; esac
  case "$2" in */Dockerfile|Dockerfile) return 0 ;; esac
  [ "$1" = 100755 ] && return 0
  return 1
}

ALL_ARR=()
while read -r mode _sha _stage path; do
  [ -n "${path:-}" ] || continue
  is_source "$mode" "$path" && ALL_ARR+=("$path")
done <<EOF
$(git -C "$REPO" ls-files -s)
EOF
[ "${#ALL_ARR[@]}" -gt 0 ] || dieblind "no code in $REPO to audit"

UNIVERSE=()
for path in "${ALL_ARR[@]}"; do
  case "$path" in "$DIR"/*) UNIVERSE+=("$path") ;; esac
done
[ "${#UNIVERSE[@]}" -gt 0 ] || dieblind "no code in $DIR/ to audit"

# Entry points: agent/ scripts (whatever a repo has there) and workflow files,
# read exactly as committed -- no host session involved.
SEEDS=()
if [ -d "$REPO/agent" ]; then
  while IFS= read -r p; do SEEDS+=("$p"); done < <(git -C "$REPO" ls-files -- agent)
fi
while IFS= read -r p; do SEEDS+=("$p"); done < <(git -C "$REPO" ls-files -- '.github/workflows/*.yml' '.github/workflows/*.yaml')
[ "${#SEEDS[@]}" -gt 0 ] || dieblind "no agent/ scripts and no .github/workflows/*.yml -- no committed entry point to start from"

declare -A REACHED=()
QUEUE=("${SEEDS[@]}")

while [ "${#QUEUE[@]}" -gt 0 ]; do
  f="${QUEUE[0]}"
  QUEUE=("${QUEUE[@]:1}")
  content="$(cat "$REPO/$f" 2>/dev/null)" || continue
  for cand in "${ALL_ARR[@]}"; do
    [ "$cand" = "$f" ] && continue
    [ -n "${REACHED[$cand]:-}" ] && continue
    base="${cand##*/}"
    [ -n "$base" ] || continue
    case "$content" in *"$base"*) REACHED[$cand]=1; QUEUE+=("$cand") ;; esac
  done
done

unreached=()
unreached_lines=0
for path in "${UNIVERSE[@]}"; do
  [ -n "${REACHED[$path]:-}" ] && continue
  n="$(wc -l < "$REPO/$path" 2>/dev/null | tr -d '[:space:]')"
  [ -n "$n" ] || n=0
  unreached+=("$n $path")
  unreached_lines=$((unreached_lines + n))
done

printf 'unreached-audit -- %d file(s) in %s/, %d reached, %d unreached\n' \
  "${#UNIVERSE[@]}" "$DIR" "$((${#UNIVERSE[@]} - ${#unreached[@]}))" "${#unreached[@]}"

if [ "${#unreached[@]}" -gt 0 ]; then
  printf '  FLAG [unreached-audit] %d file(s) in %s/ are reached by no committed entry point:\n' \
    "${#unreached[@]}" "$DIR"
  printf '%s\n' "${unreached[@]}" | sort -k2 | while read -r n path; do
    printf '    %6d  %s\n' "$n" "$path"
  done
  printf '  %d line(s) total, reachable from no agent/ script and no workflow.\n' "$unreached_lines"
  exit "$EXIT_FINDING"
fi
printf '  ok -- every file in %s/ is reached by something committed.\n' "$DIR"
exit "$EXIT_OK"
