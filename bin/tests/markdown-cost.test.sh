#!/usr/bin/env bash
#
# Usage: bin/tests/markdown-cost.test.sh   (exit 0 = all pass)

set -uo pipefail
# shellcheck source=bin/tests/lib/harness.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/markdown-cost.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT not executable"; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
# has <name> <output> <pattern>   -- output must contain pattern
# hasnt <name> <output> <pattern> -- output must NOT contain pattern
# rc <name> <expected-exit> <actual-exit>

G() { git -c user.email=t@test -c user.name=T -C "$1" "${@:2}"; }

# newrepo <name> -- a repo at $T/<name> with one base commit holding a
# pre-existing code file AND a pre-existing top-level CHANGES.md, so a later
# case can EDIT an existing document (C3) rather than only add one.
newrepo() {
  mkdir -p "$T/$1"
  G "$T/$1" init -q -b main
  printf 'echo base\n' > "$T/$1/base.sh"
  printf 'existing document\n' > "$T/$1/CHANGES.md"
  G "$T/$1" add -A
  G "$T/$1" commit -qm base
}

# lines <path> <n> <word> -- write n distinct lines (distinct so git counts
# them as n added lines, not one)
lines() { local i=1; : > "$2"; while [ "$i" -le "$1" ]; do printf '%s %d\n' "$3" "$i" >> "$2"; i=$((i+1)); done; }

# run <repo> [env...] -- sets RUN_OUT (stdout+stderr) and RUN_RC
run() { local r="$1"; shift; RUN_OUT="$(cd "$T/$r" && "$@" "$SCRIPT" main..HEAD 2>&1)"; RUN_RC=$?; }

echo "markdown-cost.test.sh"

echo "-- E. it must never answer 'found nothing' with exit 0"
# The diff-price half used to live at the bottom of the script, so a caller that
# still passes a range -- or nothing at all -- would fall off the end at 0 and
# read as "priced it, nothing wrong". That is the one bug this guard's header
# forbids, and removing a leg is exactly when it gets introduced.
newrepo unresolvable
RUN_OUT="$(cd "$T/unresolvable" && "$SCRIPT" 2>&1)"; RUN_RC=$?
rc  "E1 no mode exits 2, not 0" 2 "$RUN_RC"
has "E1 and names the mode it wanted"     "$RUN_OUT" "pass --census"
has "E1 and says the diff price is gone"  "$RUN_OUT" "The diff price was removed"

RUN_OUT="$(cd "$T/unresolvable" && "$SCRIPT" main..HEAD 2>&1)"; RUN_RC=$?
rc  "E2 a range argument is no longer a mode, and exits 2" 2 "$RUN_RC"
has "E2 and says this prices a tree"      "$RUN_OUT" "prices a TREE, not a range"

mkdir -p "$T/notarepo"
RUN_OUT="$(cd "$T/notarepo" && "$SCRIPT" --census 2>&1)"; RUN_RC=$?
rc  "E3 outside a git repository exits 2" 2 "$RUN_RC"

newrepo vendored
G "$T/vendored" checkout -q -b work
{ printf '#!/usr/bin/env bash\n'
  printf '# VENDORED. Do not edit here without recording the edit below.\n'
  printf '#   source repo:   ~/Documents/Projects/upstream\n'
  printf '#   source file:   tool.sh\n'
  for i in $(seq 1 200); do printf '# a copied explanation %d\n' "$i"; done; } > "$T/vendored/tool.sh"
G "$T/vendored" add -A
G "$T/vendored" commit -qm ported
run vendored env
rc  "F5 a header naming a source repo exits 0" 0 "$RUN_RC"
hasnt "F5 and raises no comment FLAG" "$RUN_OUT" "FLAG [comment-ratio]"

newrepo halfvendored
G "$T/halfvendored" checkout -q -b work
{ printf '#!/usr/bin/env bash\n'
  printf '# VENDORED, in spirit if not in name.\n'
  for i in $(seq 1 200); do printf '# a copied explanation %d\n' "$i"; done; } > "$T/halfvendored/tool.sh"
G "$T/halfvendored" add -A
G "$T/halfvendored" commit -qm ported
run halfvendored env
rc  "F6 the word alone, with no source repo: line, still FLAGs" 1 "$RUN_RC"
has "F6 and it is the comment-ratio flag" "$RUN_OUT" "FLAG [comment-ratio]"

echo "-- G. the tree ratchet"

newrepo ratchet
export MARKDOWN_COST_RATCHET="$T/ratchet/.ratchet"
{ printf '#!/usr/bin/env bash\n'; for i in $(seq 1 50); do printf '# line %d\n' "$i"; done; } > "$T/ratchet/tool.sh"
G "$T/ratchet" add -A
G "$T/ratchet" commit -qm seed
RUN_OUT="$(cd "$T/ratchet" && "$SCRIPT" --census 2>&1)"; RUN_RC=$?
rc  "G1 a census with no baseline exits 2, never 0" 2 "$RUN_RC"
has "G1 and says a missing baseline is not a pass" "$RUN_OUT" "not a pass"

RUN_OUT="$(cd "$T/ratchet" && "$SCRIPT" --accept 2>&1)"; RUN_RC=$?
rc  "G2 --accept seeds the baseline" 0 "$RUN_RC"
has "G2 and reports the number it recorded" "$RUN_OUT" "2 prose-bearing file(s)"

# G2b IS THE LOOPHOLE, and it is why unit 4 exists: under a line count the edit
# below paid, so truncating a comment was the cheapest way to clear the ratchet
# and the tree never got lighter for it. Under unit 4 it buys exactly nothing.
{ printf '#!/usr/bin/env bash\n'; printf '# one surviving comment\n'; } > "$T/ratchet/tool.sh"
RUN_OUT="$(cd "$T/ratchet" && "$SCRIPT" --census 2>&1)"; RUN_RC=$?
rc  "G2b shaving 49 comment lines from a surviving file exits 0" 0 "$RUN_RC"
has "G2b and does not move the number"  "$RUN_OUT" "2 prose-bearing file(s), baseline 2"
hasnt "G2b so it earns no reduction to bank" "$RUN_OUT" "run --accept to lock it in"

# G3. Growth is a file that did not carry prose before and does now.
{ printf '#!/usr/bin/env bash\n'; for i in $(seq 1 50); do printf '# line %d\n' "$i"; done; } > "$T/ratchet/tool.sh"
{ printf '#!/usr/bin/env bash\n'; printf '# a second documented tool\n'; } > "$T/ratchet/tool2.sh"
G "$T/ratchet" add -A
RUN_OUT="$(cd "$T/ratchet" && "$SCRIPT" --census 2>&1)"; RUN_RC=$?
rc  "G3 a tree that grew past the baseline exits 1" 1 "$RUN_RC"
has "G3 and FLAGs the ratchet"       "$RUN_OUT" "FLAG [prose-ratchet]"
has "G3 and says how far it rose"    "$RUN_OUT" "gained 1 prose-bearing file(s)"

# G3b. The directive only fires where there IS a merge base to blame the branch
# for -- and what it asks for now is a file, not a count of lines to shave off.
G "$T/ratchet" commit -qm grew
G "$T/ratchet" update-ref refs/remotes/origin/main HEAD~1
RUN_OUT="$(cd "$T/ratchet" && "$SCRIPT" --census 2>&1)"; RUN_RC=$?
rc  "G3b a branch that added a prose file exits 1" 1 "$RUN_RC"
has "G3b and asks for files, not lines" "$RUN_OUT" "Delete 1 file(s) this estate no longer references"
hasnt "G3b and never asks for a line count again" "$RUN_OUT" "prose line(s) from OTHER files"
G "$T/ratchet" update-ref -d refs/remotes/origin/main
G "$T/ratchet" reset -q --soft HEAD~1

# G4. And the only payment it accepts is a file that stops existing.
rm -f "$T/ratchet/tool2.sh"; G "$T/ratchet" add -A
rm -f "$T/ratchet/tool.sh";  G "$T/ratchet" add -A
RUN_OUT="$(cd "$T/ratchet" && "$SCRIPT" --census 2>&1)"; RUN_RC=$?
rc  "G4 a tree that shrank exits 0" 0 "$RUN_RC"
has "G4 and invites locking the reduction in" "$RUN_OUT" "run --accept to lock it in"

{ printf '#!/usr/bin/env bash\n'; for i in $(seq 1 50); do printf '# line %d\n' "$i"; done; } > "$T/ratchet/tool.sh"
G "$T/ratchet" add -A

# G5/G6. The ratchet only falls, and BOTH doors are shut: --accept cannot
# re-accept upward, and a hand edit that raises the number is rejected by
# --census. The hand-raise used to be advertised in the FLAG itself, and was
# taken twice on 2026-08-15 -- both times inside a PR that merged itself.
{ printf '#!/usr/bin/env bash\n'; printf '# a second documented tool\n'; } > "$T/ratchet/tool2.sh"
G "$T/ratchet" add -A
RUN_OUT="$(cd "$T/ratchet" && "$SCRIPT" --accept 2>&1)"; RUN_RC=$?
rc  "G5 --accept refuses to raise the baseline" 1 "$RUN_RC"
has "G5 and says so out loud"        "$RUN_OUT" "REFUSED"
has "G5 and names the reap instead"  "$RUN_OUT" "Reap prose instead"

# G6 needs a real merge base, because that is what the check compares against.
G6="$T/g6"; mkdir -p "$G6" && (
  cd "$G6" && git init -q -b main .
  git config user.email t@t.invalid && git config user.name t
  printf '#!/usr/bin/env bash\n# one\n' > tool.sh
  printf '# r\n100\n' > .ratchet
  git add -A && git commit -qm base
  git update-ref refs/remotes/origin/main HEAD
  printf '# r\n999\n' > .ratchet
)
RUN_OUT="$(cd "$G6" && MARKDOWN_COST_RATCHET="$G6/.ratchet" "$SCRIPT" --census 2>&1)"; RUN_RC=$?
rc  "G6 a hand-raised baseline is rejected" 1 "$RUN_RC"
has "G6 and names both numbers"   "$RUN_OUT" "RAISES the baseline from 100 to 999"
has "G6 and offers no override"   "$RUN_OUT" "there is no override"
unset MARKDOWN_COST_RATCHET

G7="$T/g7"; mkdir -p "$G7" && (
  cd "$G7" && git init -q -b main .
  git config user.email t@t.invalid && git config user.name t
  printf '#!/usr/bin/env bash\n# one\n# two\n' > real.sh
  ln -s real.sh link.sh
  printf '# r\n100\n' > .ratchet
  git add -A && git commit -qm base
  git update-ref refs/remotes/origin/main HEAD
)
RUN_OUT="$(cd "$G7" && MARKDOWN_COST_RATCHET="$G7/.ratchet" "$SCRIPT" --census 2>&1)"; RUN_RC=$?
rc  "G7 ls-files lists a tracked symlink and git archive does not, so an untouched tree must not read as growth" 0 "$RUN_RC"
hasnt "G7 a symlink target already walked once is not priced again through the link" "$RUN_OUT" "FLAG [prose-ratchet]"
has "G7 unit 1 is the path that consults the merge base, and both walkers agree there" "$RUN_OUT" "this branch is +0 against it"
unset MARKDOWN_COST_RATCHET

echo
[ "$fail" -eq 0 ] || exit 1

echo "-- P. Python docstrings are prose (since MEASURE_UNIT 2)"
# The bug this suite exists to keep fixed: until unit 2 a .py file was priced by
# its '#' comments alone, so wtul#73 could cut four module docstrings from ~135
# lines to ~45 and move the census by zero. See markdown-cost.sh's
# count_py_docstrings header.
newrepo pydoc
mkdir -p "$T/pydoc/lib"
cat > "$T/pydoc/lib/essay.py" <<'PY'
"""One.

Two.
"""
SQL = """
select 1
select 2
"""
def f():
    """Three."""
    x = """
    not prose
    """
    return x
PY
G "$T/pydoc" checkout -q -b work
G "$T/pydoc" add -A
G "$T/pydoc" commit -qm docstrings
echo "-- P(census). a docstring reap MOVES the census"
RUN_OUT="$(cd "$T/pydoc" && MARKDOWN_COST_RATCHET="$T/pydoc/.r" "$SCRIPT" --accept 2>&1)"
has "P3 --accept seeds and stamps the unit"          "$(cat "$T/pydoc/.r")" "# unit: 4"
printf '"""One."""\n' > "$T/pydoc/lib/essay.py"
G "$T/pydoc" add -A; G "$T/pydoc" commit -qm reap
after="$(cd "$T/pydoc" && MARKDOWN_COST_RATCHET="$T/pydoc/.r" "$SCRIPT" --census 2>&1)"
hasnt "P4 cutting a docstring does NOT lower the count -- the file still stands" \
                                                     "$after" "below the baseline"
G "$T/pydoc" rm -q lib/essay.py; G "$T/pydoc" commit -qm "delete it instead"
after="$(cd "$T/pydoc" && MARKDOWN_COST_RATCHET="$T/pydoc/.r" "$SCRIPT" --census 2>&1)"
has "P4b deleting the file does"                     "$after" "below the baseline"

echo "-- P(ast). the heuristic answers to Python, not to itself"
# A hand-written scanner for a language it does not parse is a guess unless
# something independent checks it. This pins count_py_docstrings to ast.
if command -v python3 >/dev/null 2>&1; then
  cat > "$T/ast_ref.py" <<'PY'
import ast, sys
src = open(sys.argv[1], encoding='utf-8').read()
lines = src.splitlines(); total = 0
for node in ast.walk(ast.parse(src)):
    body = getattr(node, 'body', None)
    if not isinstance(node, (ast.Module, ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)) or not body:
        continue
    first = body[0]
    if not (isinstance(first, ast.Expr) and isinstance(first.value, ast.Constant)
            and isinstance(first.value.value, str)):
        continue
    seg = lines[first.lineno-1:first.end_lineno]
    for d in ('"""', "'''"):
        if d in seg[0]:  seg[0]  = seg[0].split(d, 1)[-1];  break
    for d in ('"""', "'''"):
        if d in seg[-1]: seg[-1] = seg[-1].rsplit(d, 1)[0]; break
    total += sum(1 for l in seg if l.strip())
print(total)
PY
  cat > "$T/tricky.py" <<'PY'
"""Module doc line one.

Line three.
"""
SQL = """
select 1
"""
QUERY = '''
not prose
'''
def f():
    """One-liner."""
    x = """
    also not prose
    """
    return x
class C:
    '''Class doc.
    Second line.
    '''
    def g(self):
        r"""Raw doc.
        more.
        """
def h():
    # not a docstring below
    pass
foo(
    """arg string, not prose""",
)
PY
  # shellcheck disable=SC1090
  ref="$(python3 "$T/ast_ref.py" "$T/tricky.py")"
  mine="$("$SCRIPT" --count-docstrings "$T/tricky.py")"
  eq "P5 count_py_docstrings agrees with ast on the tricky file" "$mine" "$ref"
else
  echo "  SKIP P5 -- no python3 to check the heuristic against"
fi

echo "-- T. a scaffolding suffix resolves to the extension underneath (unit 4)"
newrepo scaffold
mkdir -p "$T/scaffold/examples" "$T/scaffold/docs"
TR="$T/scaffold/.r"
cens() { rm -f "$TR"; G "$T/scaffold" add -A; (cd "$T/scaffold" && MARKDOWN_COST_RATCHET="$TR" "$SCRIPT" --accept 2>&1); }
has "T0 the seeded tree holds only CHANGES.md" "$(cens)" "1 prose-bearing file(s)"

lines 20 "$T/scaffold/examples/cmd.md.template" 'a paragraph of the factory'
has "T1 foo.md.template is priced as markdown"    "$(cens)" "2 prose-bearing file(s)"

{ printf '#!/usr/bin/env bash\n'; for i in $(seq 1 5); do printf '# c %d\n' "$i"; done
  printf 'echo hi\n'; } > "$T/scaffold/examples/tool.sh.template"
has "T2 foo.sh.template is priced as shell"       "$(cens)" "3 prose-bearing file(s)"

lines 9 "$T/scaffold/examples/notes.template" 'looks like prose but has no inner extension'
has "T3 a bare foo.template is priced as nothing" "$(cens)" "3 prose-bearing file(s)"

lines 7 "$T/scaffold/docs/plain.md" 'an ordinary document'
has "T4 an ordinary foo.md is unchanged"          "$(cens)" "4 prose-bearing file(s)"

# T5. The point of pricing a scaffolding suffix is that removing one PAYS --
# a .md.template is markdown waiting to be copied, which is how prose multiplies.
newrepo reaptmpl
mkdir -p "$T/reaptmpl/examples"
lines 145 "$T/reaptmpl/examples/nightly.md.template" 'a line of the duplication factory'
G "$T/reaptmpl" add -A
G "$T/reaptmpl" commit -qm factory
TR5="$T/reaptmpl/.r"
RUN_OUT="$(cd "$T/reaptmpl" && MARKDOWN_COST_RATCHET="$TR5" "$SCRIPT" --accept 2>&1)"
has "T5 the template is counted while it exists" "$RUN_OUT" "2 prose-bearing file(s)"

G "$T/reaptmpl" rm -q examples/nightly.md.template
printf 'existing document\nheader 1\nheader 2\nheader 3\nheader 4\n' > "$T/reaptmpl/CHANGES.md"
G "$T/reaptmpl" add -A
RUN_OUT="$(cd "$T/reaptmpl" && MARKDOWN_COST_RATCHET="$TR5" "$SCRIPT" --census 2>&1)"; RUN_RC=$?
rc  "T5 removing it exits 0 even while another document grows" 0 "$RUN_RC"
has "T5 and the tree is one file lighter" "$RUN_OUT" "1 file(s) below the baseline"

echo "-- R. research/ and DESIGN-NOTES.md are measured-finding records, not priced (hf7y/chezz#89, #100)"
newrepo excluded
mkdir -p "$T/excluded/research/engine" "$T/excluded/nested/research"
TRE="$T/excluded/.r"
censE() { rm -f "$TRE"; G "$T/excluded" add -A; (cd "$T/excluded" && MARKDOWN_COST_RATCHET="$TRE" "$SCRIPT" --accept 2>&1); }
has "R0 the seeded tree holds only CHANGES.md" "$(censE)" "1 prose-bearing file(s)"

lines 60 "$T/excluded/research/engine/finding.md" 'a measured finding'
has "R1 a top-level research/ finding is not priced"      "$(censE)" "1 prose-bearing file(s)"

lines 60 "$T/excluded/nested/research/finding.md" 'a nested research finding'
has "R2 research/ is excluded at any depth"               "$(censE)" "1 prose-bearing file(s)"

lines 60 "$T/excluded/DESIGN-NOTES.md" 'a durable decision'
has "R3 top-level DESIGN-NOTES.md is not priced"           "$(censE)" "1 prose-bearing file(s)"

mkdir -p "$T/excluded/vendor"
lines 5 "$T/excluded/vendor/DESIGN-NOTES.md" 'a nested copy, not the repo record'
has "R4 only the TOP-LEVEL DESIGN-NOTES.md is exempt, a nested one is priced" "$(censE)" "2 prose-bearing file(s)"

echo "-- R(reports). reports/ is a regenerated data report, not priced (hf7y/american-cycle#232)"
mkdir -p "$T/excluded/reports" "$T/excluded/nested/reports"
lines 90 "$T/excluded/reports/suite-baseline.md" 'a regenerated report line'
has "R5 a top-level reports/ file is not priced"   "$(censE)" "2 prose-bearing file(s)"

lines 90 "$T/excluded/nested/reports/suite-baseline.md" 'a nested regenerated report line'
has "R6 reports/ is excluded at any depth"         "$(censE)" "2 prose-bearing file(s)"

echo "-- U. a unit change re-bases once, and pays for nothing"
newrepo unitchg
mkdir -p "$T/unitchg/lib"
printf '"""Doc one.\n\nDoc two.\n"""\n' > "$T/unitchg/lib/m.py"
G "$T/unitchg" add -A; G "$T/unitchg" commit -qm seed
# a unit-1 ratchet: the number a pre-docstring guard would have written
printf '# markdown-cost.ratchet\n# accepted whenever\n1\n' > "$T/unitchg/.r"
G "$T/unitchg" add -A; G "$T/unitchg" commit -qm ratchet
G "$T/unitchg" update-ref refs/remotes/origin/main main
G "$T/unitchg" checkout -q -b work
RUN_OUT="$(cd "$T/unitchg" && MARKDOWN_COST_RATCHET="$T/unitchg/.r" "$SCRIPT" --census 2>&1)"; RUN_RC=$?
rc  "U1 a stale-unit baseline does not fail a branch that adds nothing" 0 "$RUN_RC"
has "U2 it says which unit the old number was in"    "$RUN_OUT" "is unit 1, this guard measures in unit 4"
has "U3 and points at --accept to re-base"           "$RUN_OUT" "re-base"
# ...and padding the docstring in a file that already counts buys nothing,
# which under units 1-3 was the whole payment.
printf '"""Doc one.\n\nDoc two.\nDoc three.\nDoc four.\n"""\n' > "$T/unitchg/lib/m.py"
G "$T/unitchg" add -A; G "$T/unitchg" commit -qm "pad the docstring"
RUN_OUT="$(cd "$T/unitchg" && MARKDOWN_COST_RATCHET="$T/unitchg/.r" "$SCRIPT" --census 2>&1)"; RUN_RC=$?
rc  "U3b padding a file that already counts is not growth" 0 "$RUN_RC"

# ...but the branch still cannot add a prose FILE while the unit is stale
printf '"""A second documented module."""\n' > "$T/unitchg/lib/n.py"
G "$T/unitchg" add -A; G "$T/unitchg" commit -qm "add prose"
RUN_OUT="$(cd "$T/unitchg" && MARKDOWN_COST_RATCHET="$T/unitchg/.r" "$SCRIPT" --census 2>&1)"; RUN_RC=$?
rc  "U4 a stale unit does NOT excuse prose this branch adds" 1 "$RUN_RC"
has "U5 it prices against the merge base, not the stamp"     "$RUN_OUT" "adds 1 prose-bearing file(s)"
has "U5a it names the routine, not just the deficit"         "$RUN_OUT" "RUN /reap"
has "U5b and asks for a file, not a line count"              "$RUN_OUT" "Delete 1 file(s) this estate no longer references"
has "U5c and points at what nothing reads"                   "$RUN_OUT" "Shaving a comment in a file that survives moves"

echo "-- C. the directive names CANDIDATES, not just a quantity (#48)"
# A number invites the minimum: multiple PRs in one session on
# hf7y/realisateur paid this bill the cheapest way available -- twice by
# deleting the comment just written, once with a .tsv this tool prices at
# zero.
printf '#!/usr/bin/env bash\n# a big doc nothing else names\n# line two\n# line three\necho x\n' > "$T/unitchg/orphan.sh"
printf '#!/usr/bin/env bash\n# a suite, discovered by a glob and named by nothing\n# line two\necho x\n' > "$T/unitchg/lib/thing.test.sh"
printf 'orphan.sh is not mentioned here; lib/named.sh is\n' > "$T/unitchg/README.md"
printf '#!/usr/bin/env bash\n# a named file\necho x\n' > "$T/unitchg/lib/named.sh"
# hf7y/senechal's run-suites.sh globs health/test-*.sh, remedies/_test-*.sh
# and tools/test-*.py -- a PREFIX, not etalon's own *.test.sh SUFFIX. Measured
# live on hf7y/senechal#982's PR #999: every one of these ranked as an
# unnamed candidate first, alongside real suites like thing.test.sh above.
mkdir -p "$T/unitchg/health" "$T/unitchg/remedies" "$T/unitchg/tools"
printf '#!/usr/bin/env bash\n# a suite discovered by a prefix glob\necho x\n' > "$T/unitchg/health/test-prefixed.sh"
printf '#!/usr/bin/env bash\n# a suite discovered by an underscore-prefix glob\necho x\n' > "$T/unitchg/remedies/_test-prefixed.sh"
printf '# a suite discovered by a python prefix glob\n' > "$T/unitchg/tools/test_prefixed.py"
# .claude/commands/*.md is discovered a third way: the Claude Code harness
# lists the directory to find skills, never grepping the tree for the
# filename. Measured live on hf7y/senechal#973's PR: triage-run.md ranked as
# an unnamed candidate alongside the prefix-glob suites above (hf7y/etalon#52).
mkdir -p "$T/unitchg/.claude/commands"
printf '# A skill\n\nDoes a thing.\nMore prose than one line.\n' > "$T/unitchg/.claude/commands/triage-run.md"
G "$T/unitchg" add -A; G "$T/unitchg" commit -qm "candidates fixture"
RUN_OUT="$(cd "$T/unitchg" && MARKDOWN_COST_RATCHET="$T/unitchg/.r" "$SCRIPT" --census 2>&1)"
has   "C1 the directive prints where to look, not only how many"  "$RUN_OUT" "WHERE TO LOOK"
has   "C2 a file nothing names is surfaced by path"               "$RUN_OUT" "orphan.sh"
has   "C3 ...and is marked as unnamed, which is the ranking key"  "$RUN_OUT" "NOTHING NAMES IT"
# THE ONE THAT MATTERS. The first draft ranked test suites at the top,
# because a runner finds them by glob so NOTHING NAMES THEM is structurally
# true of every suite. An agent paying the bill from that list deletes the
# estate's tests -- the same cheapest-token failure, with worse blast radius.
hasnt "C4 a suite a glob discovers is NEVER a candidate"          "$RUN_OUT" "thing.test.sh"
hasnt "C4a ...nor is one a PREFIX glob discovers (test-*.sh)"     "$RUN_OUT" "test-prefixed.sh"
hasnt "C4b ...nor an underscore-prefix suite (_test-*.sh)"        "$RUN_OUT" "_test-prefixed.sh"
hasnt "C4c ...nor a python prefix suite (test_*.py)"              "$RUN_OUT" "test_prefixed.py"
hasnt "C4d ...nor a skill the harness discovers by directory"     "$RUN_OUT" "triage-run.md"
has   "C5 the list says it is candidates, not a verdict"          "$RUN_OUT" "CANDIDATE, not a verdict"
has   "C6 ...and names the failure it exists to prevent"          "$RUN_OUT" "removing the comment"

echo "-- L. a REAP pays for a file; a shave does not (#48 part 3)"
# The file unit lost sight of the thing it was built for. Measured on
# hf7y/realisateur: reaping repose -- the verb, its suite, its actuator, its
# driver bookkeeping -- paid NOTHING, because none of those files carried
# comments. The guard told an author their reap was worth nothing, which is how
# a tree keeps prose nobody reads. hf7y/etalon#48 carries the measurement.
newrepo lines
printf '#!/usr/bin/env bash\n%s\necho x\n' "$(for i in $(seq 1 40); do printf '# stale line %s\n' "$i"; done)" > "$T/lines/fat.sh"
G "$T/lines" add -A; G "$T/lines" commit -qm "a file carrying forty lines of prose"
G "$T/lines" update-ref refs/remotes/origin/main main
printf '# markdown-cost.ratchet\n# unit: 4\n# accepted whenever\n2\n' > "$T/lines/.r"
G "$T/lines" checkout -qb reap
# add a documented file AND reap the fat one's prose: the tree loses lines
printf '#!/usr/bin/env bash\n# a new file, documented\n# second line of prose\necho y\n' > "$T/lines/new.sh"
printf '#!/usr/bin/env bash\n# one line kept\necho x\n' > "$T/lines/fat.sh"
G "$T/lines" add -A; G "$T/lines" commit -qm "reap the fat file, add a documented one"
RUN_OUT="$(cd "$T/lines" && MARKDOWN_COST_RATCHET="$T/lines/.r" "$SCRIPT" --census 2>&1)"; RUN_RC=$?
rc    "L1 a branch that reaps more prose than it adds is not refused" 0 "$RUN_RC"
has   "L2 ...and it says the reap is what paid"            "$RUN_OUT" "A reap pays for a file"
has   "L3 ...naming the lines removed, not just the files" "$RUN_OUT" "prose line(s)"
has   "L4 the floor is explicitly NOT lowered by it"       "$RUN_OUT" "does not lower the floor"

# ...but a SHAVE cannot pay: trimming a comment off one surviving file while
# adding a documented one leaves the tree with more prose, not less.
G "$T/lines" checkout -q main; G "$T/lines" checkout -qb shave
printf '# markdown-cost.ratchet\n# unit: 4\n# accepted whenever\n2\n' > "$T/lines/.r"
printf '#!/usr/bin/env bash\n# another new file\n# with two lines of prose\necho y\n' > "$T/lines/new2.sh"
printf '#!/usr/bin/env bash\n%s\necho x\n' "$(for i in $(seq 1 39); do printf '# stale line %s\n' "$i"; done)" > "$T/lines/fat.sh"
G "$T/lines" add -A; G "$T/lines" commit -qm "shave one line, add a file"
RUN_OUT="$(cd "$T/lines" && MARKDOWN_COST_RATCHET="$T/lines/.r" "$SCRIPT" --census 2>&1)"; RUN_RC=$?
rc    "L5 shaving one line off a survivor does NOT pay for a file" 1 "$RUN_RC"
has   "L6 ...and the reap directive is what it gets"               "$RUN_OUT" "RUN /reap"

echo "-- U(accept). --accept still refuses to raise WITHIN a unit"
printf '# markdown-cost.ratchet\n# unit: 4\n# accepted whenever\n1\n' > "$T/unitchg/.r"
RUN_OUT="$(cd "$T/unitchg" && MARKDOWN_COST_RATCHET="$T/unitchg/.r" "$SCRIPT" --accept 2>&1)"; RUN_RC=$?
rc  "U6 same-unit raise is still REFUSED"            1 "$RUN_RC"
has "U7 and says so"                                 "$RUN_OUT" "REFUSED"

echo "-- V. a vendored file is exempt from the tree census too (hf7y/dcp-gate-site#104)"
newrepo vcensus
mkdir -p "$T/vcensus/lib"
{ printf '#!/usr/bin/env bash\n'
  printf '# VENDORED. Do not edit here without recording the edit below.\n'
  printf '#   source repo:   ~/Documents/Projects/upstream\n'
  for i in $(seq 1 30); do printf '# a copied explanation %d\n' "$i"; done; } > "$T/vcensus/lib/ported.sh"
G "$T/vcensus" add -A
G "$T/vcensus" commit -qm "add own + vendored code"
RUN_OUT="$(cd "$T/vcensus" && MARKDOWN_COST_RATCHET="$T/vcensus/.r" "$SCRIPT" --accept 2>&1)"
has "V1 --accept does not count the vendored file's comments" "$RUN_OUT" "baseline is now 1 prose line(s)"

summary
