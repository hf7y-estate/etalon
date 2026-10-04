#!/usr/bin/env bash
#
# Usage: bin/tests/path-existence-lint.test.sh   (exit 0 = all pass)

set -uo pipefail
# shellcheck source=bin/tests/lib/harness.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/path-existence-lint.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT not executable"; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

G() { git -c user.email=t@test -c user.name=T -C "$1" "${@:2}"; }

# repo <name> -- an empty repo at $T/<name> on branch main, nothing committed yet.
repo() { mkdir -p "$T/$1"; G "$T/$1" init -q -b main; }

# base <name> -- commits whatever is on disk, then pins origin/main to it, so
# the NEXT commit in that repo is what this guard prices.
base() { G "$T/$1" add -A; G "$T/$1" commit -qm base; G "$T/$1" update-ref refs/remotes/origin/main HEAD; }

run() { RUN_OUT="$(cd "$T/$1" && "$SCRIPT" 2>&1)"; RUN_RC=$?; }

echo "path-existence-lint.test.sh"

echo "-- H. not a repository, or a repository with nothing tracked"
mkdir -p "$T/notarepo"
RUN_OUT="$(cd "$T/notarepo" && "$SCRIPT" 2>&1)"; RUN_RC=$?
rc  "H1 outside a git repository is BLIND, not a pass" 6 "$RUN_RC"
has "H1 and says BLIND, not ok or found-nothing" "$RUN_OUT" "BLIND"

repo empty
G "$T/empty" commit -q --allow-empty -m base
RUN_OUT="$(cd "$T/empty" && "$SCRIPT" 2>&1)"; RUN_RC=$?
rc  "H2 no tracked files at all is BLIND" 6 "$RUN_RC"
has "H2 and names the reason" "$RUN_OUT" "no tracked files"

echo "-- R. the real case: a path that exists is not a finding"
repo real
printf 'echo hi\n' > "$T/real/base.sh"
mkdir -p "$T/real/bin"
printf 'echo hi\n' > "$T/real/bin/tool.sh"
printf 'See `bin/tool.sh` for the entry point.\n' > "$T/real/NOTES.md"
base real
run real
rc  "R1 a path the tree actually has exits 0" 0 "$RUN_RC"
has "R1 and says ok" "$RUN_OUT" "ok, every cited path exists"

echo "-- F. a path named in a tracked doc that the tree never had"
repo fake
mkdir -p "$T/fake/bin"
printf 'echo hi\n' > "$T/fake/bin/real.sh"
printf 'Run `bin/real.sh`, then `bin/ghost.sh`.\n' > "$T/fake/NOTES.md"
base fake
run fake
rc  "F1 a fabricated path exits 1" 1 "$RUN_RC"
has "F1 and names the file it was cited in"  "$RUN_OUT" "NOTES.md"
has "F1 and names the missing path"          "$RUN_OUT" "bin/ghost.sh"
hasnt "F1 and does not also flag the real one" "$RUN_OUT" "bin/real.sh"

echo "-- D. a path legitimately discussed and deleted in the same branch"
repo reaped
mkdir -p "$T/reaped/bin"
printf 'echo hi\n' > "$T/reaped/bin/old.sh"
base reaped
G "$T/reaped" rm -q bin/old.sh
printf 'This change removes `bin/old.sh`.\n' > "$T/reaped/NOTES.md"
G "$T/reaped" add -A
G "$T/reaped" commit -qm reap
run reaped
rc  "D1 discussing a file this same branch deleted is not a finding" 0 "$RUN_RC"
has "D1 and says ok"  "$RUN_OUT" "ok, every cited path exists"

echo "-- V. a vault citation is never probed"
repo vaulted
printf 'See `vault:realisateur/bin/retired.sh` for the archived version.\n' > "$T/vaulted/NOTES.md"
printf 'x\n' > "$T/vaulted/keep.txt"
base vaulted
run vaulted
rc  "V1 a vault: citation is excluded, not fabricated" 0 "$RUN_RC"

echo "-- X. a cross-repo citation names another tree, out of scope here"
repo crossrepo
printf 'See `hf7y/other-repo/bin/elsewhere.sh`.\n' > "$T/crossrepo/NOTES.md"
printf 'x\n' > "$T/crossrepo/keep.txt"
base crossrepo
run crossrepo
rc  "X1 an owner/repo-qualified citation is not checked against this tree" 0 "$RUN_RC"

echo "-- C. a fenced code block records past output, not a live claim"
repo fenced
printf 'x\n' > "$T/fenced/keep.txt"
{
  printf 'A transcript:\n'
  printf '```\n'
  printf 'Run `bin/ghost.sh` and see it fail.\n'
  printf '```\n'
} > "$T/fenced/NOTES.md"
base fenced
run fenced
rc  "C1 a citation inside a fence is not extracted" 0 "$RUN_RC"

echo "-- S. only known shapes count as a path citation"
repo shapes
printf 'x\n' > "$T/shapes/keep.txt"
printf 'Call `some_function` on the `widget` object.\n' > "$T/shapes/NOTES.md"
base shapes
run shapes
rc  "S1 inline code with no matching shape is not a path claim" 0 "$RUN_RC"

echo "-- M. a commit message this branch adds is scanned the same way"
repo commitmsg
printf 'x\n' > "$T/commitmsg/keep.txt"
base commitmsg
G "$T/commitmsg" commit -q --allow-empty -m 'landed `bin/ghost.sh`, which this repo never had'
run commitmsg
rc  "M1 a fabricated path in a new commit message exits 1" 1 "$RUN_RC"
has "M1 and attributes it to the commit"  "$RUN_OUT" "commit:"
has "M1 and names the missing path"       "$RUN_OUT" "bin/ghost.sh"

repo commitok
printf 'x\n' > "$T/commitok/keep.txt"
mkdir -p "$T/commitok/bin"
printf 'echo hi\n' > "$T/commitok/bin/real.sh"
base commitok
G "$T/commitok" commit -q --allow-empty -m 'documents `bin/real.sh`'
run commitok
rc  "M2 a commit message citing a real path exits 0" 0 "$RUN_RC"

echo "-- B. no merge base to check a deletion against is BLIND, not a pass"
repo noorigin
printf 'x\n' > "$T/noorigin/keep.txt"
printf 'See `bin/ghost.sh`.\n' > "$T/noorigin/NOTES.md"
G "$T/noorigin" add -A
G "$T/noorigin" commit -qm base
run noorigin
rc  "B1 a missing path with no merge base is BLIND" 6 "$RUN_RC"
has "B1 and says why"  "$RUN_OUT" "no merge base"

echo
summary
