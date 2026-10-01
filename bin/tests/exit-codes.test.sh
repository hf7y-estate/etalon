#!/usr/bin/env bash
# exit-codes.test.sh -- the vocabulary is defined once, and every name is distinct.
#
# Mostly the property worth pinning is not the NUMBERS -- a caller may retarget
# any of them through the environment, which is the point of `: "${VAR:=n}"`.
# It is that BLIND has a name, that the names do not collide, and that OK and
# BLIND can never become the same value, since reporting could-not-look as
# clean is the failure the file exists against.
#
# Numbers are asserted anyway, D3 and D4. BLIND=6 and REFUSED=7 are what
# bashify/skel/lib/verb.sh's verb_blind and verb_refuse exit with, and Zach's
# 2026-08-18 decision (hf7y/realisateur#334) was precisely that these two
# vocabularies are one. If a later edit drifts them apart, that decision has
# been undone silently, which is the thing this file exists to prevent.
set -uo pipefail
# shellcheck source=bin/tests/lib/harness.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/exit-codes.sh"
printf 'exit-codes.sh\n'

if [ -r "$LIB" ]; then
  ok "A1 the library exists and is readable"
else
  bad "A1 the library exists and is readable" "$LIB"
fi

# shellcheck source=/dev/null
. "$LIB"

NAMES=(EXIT_OK EXIT_FINDING EXIT_USAGE EXIT_NEEDS_SUMMON EXIT_GAP EXIT_BROKEN EXIT_BLIND EXIT_REFUSED)
for n in "${NAMES[@]}"; do
  if [ -n "${!n+set}" ]; then ok "B1 $n is defined"; else bad "B1 $n is defined"; fi
  case "${!n:-x}" in
    ''|*[!0-9]*) bad "B2 $n is a whole number" "${!n:-unset}" ;;
    *)           ok  "B2 $n is a whole number" ;;
  esac
done

# C -- OK and BLIND must never coincide. This is the load-bearing one.
if [ "$EXIT_OK" != "$EXIT_BLIND" ]; then
  ok "C1 OK and BLIND are different -- could-not-look cannot read as clean"
else
  bad "C1 OK and BLIND are different" "both are $EXIT_OK"
fi

# D -- every name distinct, so a caller switching on the code can tell them apart.
dupes="$(for n in "${NAMES[@]}"; do printf '%s\n' "${!n}"; done | sort | uniq -d | tr '\n' ' ')"
if [ -z "$dupes" ]; then
  ok "D1 all ${#NAMES[@]} codes are distinct"
else
  bad "D1 all ${#NAMES[@]} codes are distinct" "repeated: $dupes"
fi

# D2 -- GAP and REFUSED must never coincide. "not yet" filed as "never" makes
#       GAPS.md a list that cannot drain (hf7y/realisateur#373).
if [ "$EXIT_GAP" != "$EXIT_REFUSED" ]; then
  ok "D2 GAP and REFUSED are different -- a 'won't' cannot read as a 'not yet'"
else
  bad "D2 GAP and REFUSED are different" "both are $EXIT_GAP"
fi

# D3 -- the numbers match the verb runtime, which is where they were decided
#       (hf7y/realisateur#334). This is the one place a NUMBER is asserted,
#       because the whole point of the decision was that these two agree.
eq "D3 BLIND is 6, as verb_blind exits"    "$EXIT_BLIND"   "6"
eq "D4 REFUSED is 7, as verb_refuse exits" "$EXIT_REFUSED" "7"

# E -- the caller's environment wins, so a repo may retarget without editing
#      this file. `: "${VAR:=default}"` is what makes that true.
out="$(EXIT_BLIND=9 bash -c '. "$1"; printf %s "$EXIT_BLIND"' _ "$LIB")"
eq "E1 a preset value is honoured, not overwritten" "$out" "9"

# F -- sourcing prints nothing. A library that chatters breaks any caller
#      capturing stdout, and every consumer here is a guard that does.
# shellcheck source=/dev/null
noise="$(. "$LIB" 2>/dev/null)"
if [ -z "$noise" ]; then
  ok "F1 sourcing is silent on stdout"
else
  bad "F1 sourcing is silent on stdout" "$noise"
fi

summary
[ "$fail" -eq 0 ]
