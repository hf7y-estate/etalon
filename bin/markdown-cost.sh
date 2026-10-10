#!/usr/bin/env bash
# markdown-cost.sh -- give prose a price.
#
# RUNNER: .github/workflows/tests.yml
# GUARD-TEST: bin/tests/markdown-cost.test.sh
# GATE: none -- its range is a merge-base against origin/main, which a fixture repo with no origin cannot form; its suite builds a throwaway repo per case instead
#
# TRAPS (the rest of this header is in the vault):
# THE ONE BUG IT MUST NOT HAVE. In this ecosystem "found nothing" has
# repeatedly been reported as "nothing is wrong" -- a survey that reached zero
# projects printing a tidy summary and exiting 0 (see bin/lib/conf.sh's header
# for the propagation case that reached NOBODY). So every path here that cannot
# resolve the range, cannot read the diff, or cannot classify a file exits 2 and
# says which. Exit 0 from this script means one specific thing: the diff was
# read, the added lines were counted, and the count came in under the price.
# It never means the script could not tell.
#

set -uo pipefail

CLI_NAME='markdown-cost.sh'
CLI_SUMMARY='how many files in this tree carry prose, and is that more than the merge base?'
CLI_USAGE='  markdown-cost.sh --census   count prose-bearing FILES in the TREE against bin/markdown-cost.ratchet
  markdown-cost.sh --accept   record the current tree count as the baseline
  markdown-cost.sh --count-docstrings <file.py>
                              print the docstring prose lines in one file, so
                              the heuristic can be checked against Python ast'
CLI_FLAGS='--census --accept --count-docstrings'
CLI_EXITS='  0  the tree was counted and it is at or under the merge base
  1  the tree rose above the prose ratchet
  2  the tree could not be counted or a file could not be classified --
     NEVER "I looked and found nothing"'
CLI_POSITIONAL=any
. "$(dirname "${BASH_SOURCE[0]}")/lib/cli-guard.sh"
cli_guard "$@"

# --- what language is a file's prose written in? ------------------------------
# ONE predicate, read by the census and by count_prose, so the two cannot
# disagree about what a file is. A trailing SCAFFOLDING suffix is not a language: a .md.template
# is markdown waiting to be COPIED, which is how prose multiplies -- #18 found
# a 7.5 KB one free to keep, free to copy, and worth nothing when deleted.
# Only suffixes this estate uses; a bare foo.template is not guessed at.
prose_lang() { # <path> -> 'h', 'j', 'm', 'p', or empty for a file we do not price
  local f="$1" first
  case "$f" in *.template|*.tmpl|*.example|*.in) f="${f%.*}" ;; esac
  case "$f" in
    *.md|*.markdown)                       printf 'm'; return ;;
    *.sh|*.bash|*.conf|*.yml|*.yaml)       printf 'h'; return ;;
    *.py)                                  printf 'p'; return ;;
    *.mjs|*.js)                            printf 'j'; return ;;
  esac
  # etalon#11: a declared VERB has no extension, by convention -- the bare
  # name is what lands on PATH. The case above prices every one of them at
  # zero no matter how much prose it carries. Sniff the shebang the same way
  # state-prose-lint.sh already does for the same reason (etalon#24).
  first="$(head -n 1 -- "$1" 2>/dev/null)"
  case "$first" in
    '#!'*/sh|'#!'*/sh\ *|'#!'*/bash|'#!'*/bash\ *) printf 'h' ;;
    '#!'*env\ sh|'#!'*env\ sh\ *|'#!'*env\ bash|'#!'*env\ bash\ *) printf 'h' ;;
    '#!'*/python*|'#!'*env\ python*)               printf 'p' ;;
  esac
}

prose_excluded() { # <path> -> 0 if no rule should grade this file
  case "$1" in residue/*|*/residue/*|canon/*|*/canon/*) return 0 ;; esac
  # research/ is a repo's own measured-finding record (hf7y/chezz#89, #100):
  # a doc that reports what was found, not a mechanism, and the census would
  # otherwise price every finding as growth with no way to pay it off short of
  # deleting the finding. DESIGN-NOTES.md is the same shape one level up -- a
  # single durable decision record a repo is expected to keep appending to.
  case "$1" in research/*|*/research/*|DESIGN-NOTES.md) return 0 ;; esac
  # reports/ is the same shape one level further: a tracked, periodically
  # REGENERATED data report (hf7y/american-cycle#232), not hand-authored prose.
  # A full regeneration after an upstream change can rewrite most of the file
  # on values alone, with no way to pay that off short of not regenerating it.
  case "$1" in reports/*|*/reports/*) return 0 ;; esac
  prose_vendored_elsewhere "$1" && return 0
  return 1
}

# A vendored/canonical-elsewhere file is prose authored somewhere else, not in
# this tree -- the same shape as the residue/canon exemption above, extended
# from "retired in place" to "written in place" (hf7y/dcp-gate-site#104). A
# wholesale port of another repo's suite, headed per the estate's own
# do-not-edit-here convention, otherwise inflates this repo's own census for
# prose no local reap can ever pay off: the repo is explicitly told not to
# hand-edit the file.
VENDOR_HEADER_LINES=20
prose_vendored_elsewhere() { # <path> -> 0 if the header both claims and names an upstream source
  [ -n "$(prose_lang "$1")" ] || return 1
  [ -f "$1" ] || return 1
  local head
  head="$(head -n "$VENDOR_HEADER_LINES" -- "$1" 2>/dev/null)"
  case "$head" in
    *'VENDORED.'*'source repo:'*)             return 0 ;;
    *'CANONICAL COPY LIVES AT'*'canonical:'*) return 0 ;;
  esac
  return 1
}

# is_comment <lang> <line> -> 0 if this line is prose. Callers skip blanks.
# j (JS) still matches a LEADING '//'/'/*'/'*' only -- a trailing '//' comment
# is the same gap closed below for h/p and is not fixed here.
is_comment() {
  local s="$2"
  s="${s#"${s%%[![:space:]]*}"}"     # strip leading whitespace
  case "$1" in
    j) case "$s" in '//'*|'/*'*|'*'*) return 0 ;; esac ;;
  esac
  return 1
}

# hash_comment_lines <path> -> count of lines carrying a REAL '#' comment,
# leading OR TRAILING. hf7y/etalon#48 (2026-09-23): `bin/repose.sh` rode its
# entire rationale on a comment trailing `set -uo pipefail`, which a
# leading-only match never sees -- so the file was never prose-bearing and
# deleting all 57 lines of it paid nothing. "Move the comment one column
# right" must not be a free way off the census.
#
# A '#' only starts a comment at the START OF A WORD (preceded by whitespace
# or start-of-line) and outside a quote -- the same rule bash itself uses, and
# it is what keeps `${f#./}` / `$#` (never preceded by whitespace) from being
# misread as a comment. Quotes are tracked char-by-char because a '#' inside
# one, e.g. `echo "a # b"`, is data, not prose.
hash_comment_lines() { # <path> -> count
  awk '
    {
      line = $0; s = line; sub(/^[ \t]+/, "", s)
      if (s == "" || substr(s, 1, 2) == "#!") next
      insq = 0; indq = 0; esc = 0; prevspace = 1; found = 0
      n = length(line)
      for (i = 1; i <= n; i++) {
        c = substr(line, i, 1)
        if (esc)               { esc = 0; prevspace = 0; continue }
        if (indq) {
          if (c == "\\")        { esc = 1; continue }
          if (c == "\042")      { indq = 0 }
          prevspace = 0; continue
        }
        if (insq) {
          if (c == "\047")      { insq = 0 }
          prevspace = 0; continue
        }
        if (c == "\\")          { esc = 1; prevspace = 0; continue }
        if (c == "\042")        { indq = 1; prevspace = 0; continue }
        if (c == "\047")        { insq = 1; prevspace = 0; continue }
        if (c == "#") {
          if (prevspace)        { found = 1; break }
          prevspace = 0; continue
        }
        if (c == " " || c == "\t") { prevspace = 1; continue }
        prevspace = 0
      }
      if (found) n_found++
    }
    END { print n_found + 0 }
  ' "$1"
}

# --- Python docstrings are prose, and used not to be ------------------------
# Unit 2's case, the same shape as the scaffolding gap above: wtul#73 reaped
# module docstrings and this census never moved.
#
# A docstring is a triple-quoted block that BEGINS its line (so `SQL = """..."""`
# stays data, not prose) and sits in first-statement position: start of file, or
# after a header line ending in ':'. That pair of conditions is what separates a
# docstring from a triple-quoted string literal, and it is checked against
# Python's own `ast` in bin/tests/markdown-cost.test.sh rather than asserted.
# Delimiter-only lines and blanks are not prose, exactly as a ``` fence is not.
count_py_docstrings() { # <path> -> docstring prose lines
  awk '
  { line = $0; s = line; sub(/^[ \t]+/, "", s)
    if (indoc) {
      if (index(s, q) == 1 && length(s) == 3) { indoc = 0; next }
      p = index(line, q)
      if (p > 0) { rest = substr(line, 1, p - 1); indoc = 0
                   if (rest ~ /[^ \t]/) n++; next }
      if (s != "") n++
      next }
    if (s ~ /^[ \t]*#/) next
    if (s == "") next
    # {0,2} is a POSIX interval expression; mawk, the awk this script runs
    # under here (readlink -f $(which awk)), does not implement intervals
    # and matches empty rather than erroring, so the prefix below was never
    # stripped and a prefixed docstring (r""" f""" rb""") was never counted.
    # Independent optional letter groups are the portable equivalent.
    t = s; sub(/^[A-Za-z]?[A-Za-z]?/, "", t)     # r"""  f"""  rb"""
    if (index(t, "\"\"\"") == 1) q = "\"\"\""
    else if (index(t, "'"'"'") == 1) q = "'"'"'"
    else { prev = s; prevset = 1; next }
    if (!(prevset == 0 || prev ~ /:[ \t]*$/)) { prev = s; prevset = 1; next }
    body = substr(t, 4); cp = index(body, q)
    if (cp > 0) { head = substr(body, 1, cp - 1)
                  if (head ~ /[^ \t]/) n++
                  prev = s; prevset = 1; next }
    if (body ~ /[^ \t]/) n++
    indoc = 1; prevset = 1; next }
  END { print n+0 }' "$1"
}

die2() { printf '%s: %s\n' "$CLI_NAME" "$*" >&2; exit 2; }

# --- the census and its ratchet ----------------------------------------------
RATCHET="${MARKDOWN_COST_RATCHET:-$(dirname "${BASH_SOURCE[0]}")/markdown-cost.ratchet}"

# MEASURE_UNIT is the version of the QUESTION, not of the script. Bump it only
# when a change makes an old baseline mean something different -- a new language
# priced, a predicate widened. A bug fix that makes the same question answered
# correctly does NOT bump it.
#
#   1  markdown + '#' and '//' comment lines
#   2  ...and Python docstrings (2026-08-26)
#   3  ...and files behind a scaffolding suffix (hf7y/etalon#18)
#   4  PROSE-BEARING FILES, not prose lines
#   5  ...and a '#' comment TRAILING code, not just leading it (hf7y/etalon#48)
#   6  ...and an extensionless file whose shebang names sh/bash/python
#      (hf7y/etalon#11)
#
# WHY THIS EXISTS AT ALL. Unit 2 raised five of six estate repos above their
# committed floor at once (crt +3278, wtul +1933, senechal +693). The ratchet
# only falls and --accept refuses to raise, so without this the whole estate
# wedges: no PR passes anywhere, and the only way out is the hand edit the
# guard is built to reject. A measurement change is not prose growth, and must
# not be charged as it.
#
# It is NOT an override, and it is deliberately not reachable from a repo. On a
# unit mismatch the committed integer is never read as a floor -- it is in the
# wrong unit and says nothing -- so the floor becomes the merge-base tree,
# measured LIVE in the current unit. Editing the stamp in your own ratchet
# therefore buys nothing: the branch still cannot add a line, because the
# comparison it must pass never involved the stamped number.
# Unit 4 is not a widened predicate -- it is a different question, and the
# reason is an invariant about what a unit can be paid in. A LINE count is
# payable by rewriting your own lines, so the cheapest way to clear it is to
# truncate a comment in a file that stays; the branch pays and the tree does
# not, which is how a comment comes to end mid-sentence. A FILE count admits
# only one payment: a file stops existing. Shaving is then worth exactly
# nothing, and the guard can no longer ask for a move that damages the tree.
# The evidence this was reversed on is in hf7y/realisateur#1142.
#
# Unit 5 widens what a '#' counts as: previously only a line BEGINNING with
# one was prose, so a file that carried its entire rationale as a comment
# trailing a code line (`set -uo pipefail  # ...`) was never prose-bearing and
# a branch deleting it paid nothing -- found live in hf7y/realisateur#1240,
# see hf7y/etalon#48. The old baseline answers "how many files have a LEADING
# '#' comment", which is a smaller count than this unit measures; it is not
# comparable, so it bumps rather than silently inflating every repo's number.
# Unit 6 widens what is CLASSIFIED, not just what counts as a comment within a
# classified file. `prose_lang()` priced by extension alone, and a declared
# verb -- an executable `bin/<name>` with no extension, the estate's own
# convention for what lands on PATH -- fell into the unpriced `*)` arm no
# matter how much prose it carried (hf7y/etalon#11: `bin/consigne`,
# `bin/fonde` and others measured at zero for exactly this reason). The old
# baseline answers "how many files are prose-bearing by EXTENSION", which
# undercounts relative to this unit wherever a repo has verbs; it is not
# comparable, so it bumps.
MEASURE_UNIT=6

CANDIDATES_MAX="${MARKDOWN_COST_CANDIDATES:-10}"

# A NUMBER INVITES THE MINIMUM (hf7y/etalon#48). Zach, after watching a session
# pay this bill the cheapest way available every time:
# "the problem was agents trying to shave their own prose down at the margins
# rather than taking out the trash. what can change that behavior?"
# Unit 4 already made shaving worthless. What it did not do is say WHICH files
# to look at, so the author -- mid-task and optimising to land a PR -- hunts for
# the cheapest token that clears the bill instead. Twice that was deleting the
# comment they had just written; once it was a .tsv this tool prices at zero.
# The census already knows every file's prose count. Ranking them by "does
# anything name this" makes the cheapest action the right one.
# DISCOVERED, NOT NAMED. A suite is found by a runner globbing `*.test.sh`, a
# workflow by GitHub reading `.github/workflows/`, so NOTHING NAMES THEM is
# structurally true of every one of them and says nothing about whether they are
# dead. The first draft of this list ranked eight test suites at the top -- an
# agent paying the bill from it would have deleted the estate's tests, which is
# the same cheapest-token failure this list exists to stop, with worse blast
# radius. Anything a glob reaches is not a candidate here.
#
# `*.test.sh` is etalon's own convention; it is not the only one a glob
# reaches. hf7y/senechal's run-suites.sh globs `health/test-*.sh`,
# `remedies/_test-*.sh`, `bin/test-*.sh` and `tools/test-*.py` -- a
# prefix, not a suffix -- and this list ranked every one of them as an
# unnamed candidate first (measured live on hf7y/senechal#982's PR #999).
#
# `.claude/commands/*.md` is discovered the same way, by a different
# reader: the Claude Code harness lists that directory to find skills,
# never grepping the tree for the filename. Nothing NAMES a skill any
# more than something names a test suite a glob finds -- measured live
# on hf7y/senechal#973's PR, where `.claude/commands/triage-run.md`
# ranked as an unnamed candidate alongside 25 false-positive test suites
# (hf7y/etalon#52).
candidate_excluded() { # <path> -> 0 if a runner or a platform discovers it
  local b; b="$(basename -- "$1")"
  case "$1" in
    *.test.sh|*/tests/*|*/test/*)      return 0 ;;
    .github/workflows/*|.github/*)     return 0 ;;
    .claude/commands/*.md)             return 0 ;;
    */conftest.py|*/__init__.py)       return 0 ;;
  esac
  case "$b" in
    test-*|_test-*|test_*)             return 0 ;;
  esac
  return 1
}

reap_candidates() { # -> refs<TAB>prose-lines<TAB>path, worst first
  local f lang n refs
  git ls-files -z | while IFS= read -r -d '' f; do
    [ -L "$f" ] && continue
    [ -f "$f" ] || continue
    prose_excluded "$f" && continue
    candidate_excluded "$f" && continue
    lang="$(prose_lang "$f")"
    [ -n "$lang" ] || continue
    n="$(count_prose "$lang" "$f")"
    [ "$n" -gt 0 ] || continue
    # Does anything else in the tree NAME it? The first question a human asks,
    # and the one the old directive left them to answer by hand. A file nothing
    # names is not proof of death -- a crontab on another host may call it
    # (hf7y/realisateur#511 deleted its only outside observer that way) -- so
    # these are CANDIDATES to look at, never a delete list to execute.
    refs="$(git grep -l --fixed-strings -- "$(basename "$f")" 2>/dev/null | grep -cvFx "$f")"
    printf '%s\t%s\t%s\n' "$refs" "$n" "$f"
  done | sort -t"$(printf '\t')" -k1,1n -k2,2nr | head -n "$CANDIDATES_MAX"
}

reap_directive() { # <deficit> -- what to do about it, not just that it happened
  # The only payment this unit accepts is a FILE that stops existing. Editing
  # one buys nothing, by construction, so there is no point telling anyone to.
  printf '        RUN /reap. Delete %d file(s) this estate no longer references.\n' "$1"
  printf '        Not lines -- files. Shaving a comment in a file that survives moves\n'
  printf '        this number by zero.\n'
  local cand; cand="$(reap_candidates)"
  if [ -n "$cand" ]; then
    printf '\n        WHERE TO LOOK -- prose-bearing files, fewest references first:\n'
    printf '%s\n' "$cand" | while IFS="$(printf '\t')" read -r refs lines path; do
      if [ "$refs" -eq 0 ]; then
        printf '          %4s prose lines  NOTHING NAMES IT  %s\n' "$lines" "$path"
      else
        printf '          %4s prose lines  named by %-3s      %s\n' "$lines" "$refs" "$path"
      fi
    done
    printf '        A file nothing names is a CANDIDATE, not a verdict: check what calls\n'
    printf '        it from another host before deleting. Paying by removing the comment\n'
    printf '        you just wrote is the failure this list exists to prevent.\n'
  fi
}

ratchet_unit() { # <file-or-stdin-text> -> the unit a ratchet was written in
  local u
  u="$(printf '%s\n' "$1" | sed -n 's/^# *unit: *\([0-9][0-9]*\).*/\1/p' | head -1)"
  printf '%s' "${u:-1}"     # every ratchet written before the stamp is unit 1
}

# census_stream reads NUL-separated repo-relative paths and counts how many of
# them carry prose at all.
# Every caller must hand it the same file set for a given tree, or a working
# tree and a ref stop being comparable. NOT a second checkout -- creating one is
# a violation bin/no-worktree-lint.sh exists to catch, and it caught this.
census_stream() {
  local f lang n=0
  while IFS= read -r -d '' f; do
    f="${f#./}"
    [ -L "$f" ] && continue
    [ -f "$f" ] || continue
    prose_excluded "$f" && continue
    lang="$(prose_lang "$f")"
    [ -n "$lang" ] || continue
    # ONE PER FILE, not one per line. A file either carries prose or it does
    # not; how much it carries is not what this ratchet is for. Shaving a
    # comment inside a file that survives moves this number by zero, which is
    # the whole point -- see reap_directive.
    if [ "$(count_prose "$lang" "$f")" -gt 0 ]; then n=$((n + 1)); fi
  done
  printf '%d' "$n"
}

census() { git ls-files -z | census_stream; }

# THE OTHER HALF OF THE MEASUREMENT, and the one the unit change lost sight of.
# A branch can delete a whole mechanism and pay NOTHING against the file count,
# because the files it removed carried no comments -- while the one file it adds
# does. That is the guard telling an author their reap was worth nothing, and
# hf7y/etalon#48 carries the case that forced this.
line_stream() { # NUL-separated paths -> total prose LINES across them
  local f lang n=0
  while IFS= read -r -d '' f; do
    [ -L "$f" ] && continue
    [ -f "$f" ] || continue
    prose_excluded "$f" && continue
    lang="$(prose_lang "$f")"
    [ -n "$lang" ] || continue
    n=$((n + $(count_prose "$lang" "$f")))
  done
  printf '%d' "$n"
}

line_census() { git ls-files -z | line_stream; }

line_census_ref() { # <ref> -> total prose lines in that tree, or empty if unreadable
  local d out=''
  d="$(mktemp -d)" || return 1
  if git archive --format=tar "$1" 2>/dev/null | tar -x -C "$d" 2>/dev/null; then
    out="$( cd "$d" && find . -type f -print0 | line_stream )"
  fi
  rm -rf "$d"
  printf '%s' "$out"
}

# A REAP PAYS FOR A FILE. Not a shave: the deleted lines must outnumber the
# added ones across the whole tree, which a comment trimmed off one surviving
# file cannot do. The file count still has to come down eventually -- this
# forgives a DEFICIT, it never lowers the floor.
lines_paid() { # <mb-ref> -> 0 if this branch removes more prose lines than it adds
  local before after
  before="$(line_census_ref "$1")"
  after="$(line_census)"
  [ -n "$before" ] && [ -n "$after" ] || return 1
  [ "$after" -lt "$before" ] || return 1
  printf '%s %s' "$before" "$after"
}

census_ref() { # <ref> -> prose-bearing files in that tree, or empty if unreadable
  local d out=''
  d="$(mktemp -d)" || return 1
  if git archive --format=tar "$1" 2>/dev/null | tar -x -C "$d" 2>/dev/null; then
    out="$( cd "$d" && find . -type f -print0 | census_stream )"
  fi
  rm -rf "$d"
  printf '%s' "$out"
}

count_prose() { # <lang> <path> -> prose line count for one file
  if [ "$1" = m ]; then
    # Everything outside a ``` fence. The fence lines themselves are not prose.
    awk '/^[ \t]*```/{fence=!fence; next} {if($0~/^[ \t]*$/)next; if(!fence)n++} END{print n+0}' "$2"
  elif [ "$1" = h ] || [ "$1" = p ]; then
    local n
    n="$(hash_comment_lines "$2")"
    [ "$1" = p ] && n=$((n + $(count_py_docstrings "$2")))
    printf '%d' "$n"
  else
    local line s n=0
    while IFS= read -r line || [ -n "$line" ]; do
      s="${line#"${line%%[![:space:]]*}"}"
      [ -n "$s" ] || continue
      is_comment "$1" "$line" && n=$((n + 1))
    done < "$2"
    printf '%d' "$n"
  fi
}

# Exposed so bin/tests can pin this heuristic to Python's own ast. A scanner for
# a language it does not parse is a guess until something independent checks it.
if [ "${1:-}" = --count-docstrings ]; then
  [ $# -eq 2 ] || die2 "--count-docstrings takes exactly one file, got $(($# - 1))"
  [ -f "$2" ] || die2 "no such file: $2"
  count_py_docstrings "$2"
  exit 0
fi

if [ "${1:-}" = --census ] || [ "${1:-}" = --accept ]; then
  git rev-parse --git-dir >/dev/null 2>&1 || die2 "not inside a git repository"
  now="$(census)"
  [ -n "$now" ] || die2 "the census produced no count -- refusing to report a number I did not measure"
  if [ "${1:-}" = --accept ]; then
    # A ratchet that can be re-accepted upward is not a ratchet. If the tree
    # has grown, --accept refuses; reap prose, do not move the floor.
    if [ -f "$RATCHET" ]; then
      prev_text="$(cat "$RATCHET")"
      prev="$(printf '%s\n' "$prev_text" | grep -v '^#' | tr -d '[:space:]')"
      prev_unit="$(ratchet_unit "$prev_text")"
      case "$prev" in ''|*[!0-9]*) prev='' ;; esac
      # Across a unit change the old number is not a smaller measurement of the
      # same thing, so "above it" is not growth. Re-base once, and say so.
      if [ -n "$prev" ] && [ "$prev_unit" != "$MEASURE_UNIT" ]; then
        printf 'markdown-cost --accept -- RE-BASING from unit %s to unit %s.\n' "$prev_unit" "$MEASURE_UNIT"
        printf '  The old baseline of %s is in a unit this guard no longer measures in;\n' "$prev"
        printf '  %s is the same tree re-measured, not prose that was added.\n' "$now"
        prev=''
      fi
      if [ -n "$prev" ] && [ "$now" -gt "$prev" ]; then
        printf 'markdown-cost --accept -- REFUSED. The tree is %d file(s) ABOVE the\n' "$((now - prev))" >&2
        printf '  baseline of %s, and this ratchet only falls. Reap prose instead.\n' "$prev" >&2
        exit 1
      fi
    fi
    # SEEDING BEFORE `git add` IS THE RECURRING TRAP, and it is silent.
    # census() is `git ls-files`, so a prose file that is written but not yet
    # STAGED is not counted -- the baseline lands too low and the very next
    # --census fails on the commit that seeded it. It has bitten four separate
    # ports; hf7y/ecosim#73 diagnosed it after the third. A warning is cheap
    # and the alternative is remembering, which has not worked.
    untracked="$(git ls-files --others --exclude-standard -z 2>/dev/null \
      | { n=0; while IFS= read -r -d '' u; do
            prose_excluded "$u" && continue
            [ -n "$(prose_lang "$u")" ] && n=$((n+1))
          done; printf '%s' "$n"; })"
    if [ "${untracked:-0}" -gt 0 ]; then
      printf 'markdown-cost --accept -- WARNING: %s prose file(s) are UNTRACKED and\n' "$untracked" >&2
      printf '  therefore NOT in this baseline. census() reads `git ls-files`. Stage them\n' >&2
      printf '  and re-run --accept, or the next --census fails on this very commit.\n' >&2
    fi
    printf '# markdown-cost.ratchet -- prose-bearing FILES in this tree. SHRINKS ONLY.\n# Written by markdown-cost.sh --accept, which refuses to raise it. A hand\n# edit that raises it is rejected by --census. See hf7y/etalon.\n# unit: %s -- what was measured. A number from another unit is not a floor.\n# accepted %s\n%s\n' \
      "$MEASURE_UNIT" "$(date -Is)" "$now" > "$RATCHET" || die2 "cannot write $RATCHET"
    printf 'markdown-cost --accept -- baseline is now %s prose-bearing file(s).\n' "$now"
    exit 0
  fi
  [ -f "$RATCHET" ] || die2 "no ratchet at $RATCHET -- run --accept to seed it. A missing baseline is not a pass."
  was_text="$(cat "$RATCHET")"
  was="$(printf '%s\n' "$was_text" | grep -v '^#' | tr -d '[:space:]')"
  case "$was" in ''|*[!0-9]*) die2 "unreadable baseline in $RATCHET: '$was'" ;; esac
  was_unit="$(ratchet_unit "$was_text")"
  stale_unit=0
  [ "$was_unit" = "$MEASURE_UNIT" ] || stale_unit=1
  if [ "$stale_unit" = 1 ]; then
    printf 'markdown-cost --census -- %s prose-bearing file(s); baseline %s is unit %s, this guard measures in unit %s.\n' \
      "$now" "$was" "$was_unit" "$MEASURE_UNIT"
  else
    printf 'markdown-cost --census -- %s prose-bearing file(s), baseline %s\n' "$now" "$was"
  fi

  # A branch answers for the prose IT adds, not for main moving beneath it.
  # Found on this guard's own first CI run: the branch was under its own
  # baseline and still failed, because main had gained 235 lines since it was
  # cut. On an absolute gate every PR re-accepts, and re-accepting on autopilot
  # is how a ratchet loosens itself. So the FLAG needs both conditions.
  base=''
  mb=''
  if git rev-parse --verify -q origin/main >/dev/null 2>&1; then
    mb="$(git merge-base HEAD origin/main 2>/dev/null)" || mb=''
    [ -n "$mb" ] && base="$(census_ref "$mb")"
  fi

  # THE BASELINE ITSELF ONLY FALLS. Raising it by hand was an affordance this
  # guard printed in its own FLAG, and it was taken twice in one day -- once
  # to fit three guards, once to fit a rollout -- each time with a written
  #   [rest: vault:realisateur/guard-archaeology-20260817.md]
  if [ -n "$mb" ]; then
    prev_text="$(git show "$mb:${RATCHET#"$(git rev-parse --show-toplevel)/"}" 2>/dev/null)"
    prev="$(printf '%s\n' "$prev_text" | grep -v '^#' | tr -d '[:space:]')"
    case "$prev" in ''|*[!0-9]*) prev='' ;; esac
    # Two numbers in different units are not a raise; the re-base IS the change.
    [ "$(ratchet_unit "$prev_text")" = "$was_unit" ] || prev=''
    if [ -n "$prev" ] && [ "$was" -gt "$prev" ]; then
      printf '  FLAG [prose-ratchet] this branch RAISES the baseline from %s to %s.\n' "$prev" "$was"
      printf '        The ratchet only falls, and there is no override. Reap prose until\n'
      printf '        the tree fits, or leave the number alone.\n'
      exit 1
    fi
  fi

  if [ "$stale_unit" = 1 ]; then
    # The number in the file answers a question this guard no longer asks, so it
    # is not consulted. The merge-base tree is, measured live in the current
    # unit -- which is why a hand-edited stamp wins nothing: this comparison
    # never reads the stamped integer.
    if [ -z "$base" ]; then
      printf '  FLAG [prose-ratchet] the baseline is unit %s and there is no merge base to\n' "$was_unit"
      printf '        re-measure against, so this branch cannot be priced at all.\n'
      printf '        Fetch origin/main, or run --accept to re-base deliberately.\n'
      exit 1
    fi
    printf '  merge base holds %s in unit %s; this branch is %+d against it.\n' "$base" "$MEASURE_UNIT" "$((now - base))"
    if [ "$now" -gt "$base" ]; then
      if paid="$(lines_paid "$mb")"; then
        pb="${paid%% *}"; pa="${paid##* }"
        printf '  PAID [prose-ratchet] this branch adds %d prose-bearing file(s), and removes\n' "$((now - base))"
        printf '        %d prose line(s): %s -> %s across the tree. A reap pays for a file.\n' "$(( pb - pa ))" "$pb" "$pa"
        printf '        The file count still has to come down; this forgives the deficit,\n'
        printf '        it does not lower the floor.\n'
      else
        printf '  FLAG [prose-ratchet] this branch adds %d prose-bearing file(s).\n' "$((now - base))"
        printf '        (The unit changed since %s was written, so that number is not the\n' "$RATCHET"
        printf '        floor here -- the merge-base tree is. Re-basing does not pay for\n'
        printf '        prose this branch adds.)\n'
        reap_directive "$((now - base))"
        exit 1
      fi
    fi
    printf '  ok -- adds nothing over the merge base. Run --accept to re-base %s to unit %s.\n' "$RATCHET" "$MEASURE_UNIT"
    exit 0
  fi

  if [ "$now" -gt "$was" ]; then
    if [ -z "$base" ]; then
      printf '  FLAG [prose-ratchet] the tree gained %d prose-bearing file(s) over the baseline,\n' "$((now - was))"
      printf '        and there is no merge base to say whether this branch is responsible.\n'
      exit 1
    fi
    printf '  merge base holds %s; this branch is %+d against it.\n' "$base" "$((now - base))"
    if [ "$now" -gt "$base" ]; then
      if paid="$(lines_paid "$mb")"; then
        pb="${paid%% *}"; pa="${paid##* }"
        printf '  PAID [prose-ratchet] this branch adds %d prose-bearing file(s), and removes\n' "$((now - base))"
        printf '        %d prose line(s): %s -> %s across the tree. A reap pays for a file.\n' "$(( pb - pa ))" "$pb" "$pa"
        printf '        The file count still has to come down; this forgives the deficit,\n'
        printf '        it does not lower the floor.\n'
      else
        printf '  FLAG [prose-ratchet] this branch adds %d prose-bearing file(s), and the tree is\n' "$((now - base))"
        printf '        already %d over the baseline of %s.\n' "$((now - was))" "$was"
        printf '        The ratchet only falls, and raising %s is\n' "$RATCHET"
        printf '        rejected too.\n'
        reap_directive "$((now - base))"
        exit 1
      fi
    fi
    printf '  over the baseline, but not by this branch -- main drifted. Not this PR to answer for.\n'
  fi
  [ "$now" -lt "$was" ] && printf '  %d file(s) below the baseline -- run --accept to lock it in.\n' "$((was - now))"
  printf '  ok -- at or under the baseline.\n'
  exit 0
fi

# NO MODE IS NOT A PASS. The diff-price half used to live here, so every caller
# that still runs this with no arguments -- a consumer whose workflow was not
# updated, a habit, a script -- would otherwise fall off the end at 0 and read
# as "priced it, nothing wrong". That is the one bug this file's header says it
# must not have. Say what happened and exit 2.
die2 "no mode given. This prices a TREE, not a range: pass --census (or --accept to seed a baseline). The diff price was removed -- a branch is no longer billed for the share of its added lines that are prose."
