#!/usr/bin/env bash
# mechanism-budget.sh -- a new mechanism must be paid for by two retirements.
# RUNNER: .github/workflows/tests.yml
# GUARD-TEST: bin/tests/mechanism-budget.test.sh
#
# TRAPS: tests are excluded; the mode comes from the INDEX, so seeding before `git add` lands the baseline low.

set -uo pipefail

CLI_NAME='mechanism-budget.sh'
CLI_SUMMARY='how many mechanisms does this repo carry, against a budget that only falls?'
CLI_USAGE='  mechanism-budget.sh                   count mechanisms in the repo at $PWD
  mechanism-budget.sh --repo <dir>      count mechanisms in <dir>
  mechanism-budget.sh --repo <dir> --accept   record the count as the baseline
  mechanism-budget.sh --repo <dir> --unwired  find an executable under bin/
                                       that names no verified caller (etalon#127:
                                       built but not wired is the failure that
                                       went uncaught). No ratchet, report always.'
CLI_FLAGS='--repo --accept --unwired'
CLI_EXITS='  0  the repo was read and it is at or under the baseline, or --unwired found none
  1  over the baseline, --accept was asked to raise it, or --unwired found one
  2  usage error, or an unreadable baseline
  6  BLIND: not a repository, or the census could not read the index'
CLI_POSITIONAL=any
. "$(dirname "${BASH_SOURCE[0]}")/lib/cli-guard.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib/exit-codes.sh"
cli_guard "$@"

die2()    { printf '%s: %s\n' "$CLI_NAME" "$*" >&2; exit "$EXIT_USAGE"; }
dieblind(){ printf '%s: BLIND -- %s\n' "$CLI_NAME" "$*" >&2; exit "$EXIT_BLIND"; }

REPO=.
ACCEPT=0
UNWIRED=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) [ $# -ge 2 ] || die2 "--repo needs a directory"; REPO="$2"; shift 2 ;;
    --accept) ACCEPT=1; shift ;;
    --unwired) UNWIRED=1; shift ;;
    *) die2 "unexpected argument: $1" ;;
  esac
done
[ "$ACCEPT" -eq 1 ] && [ "$UNWIRED" -eq 1 ] && die2 "--accept and --unwired are exclusive"
[ -d "$REPO" ] || dieblind "no such directory: $REPO"
REPO="$(cd "$REPO" && pwd)" || dieblind "cannot enter $REPO"
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || dieblind "$REPO is not a git repository"

RATCHET="${MECHANISM_BUDGET_RATCHET:-$REPO/.mechanism-ratchet}"

is_test() {
  case "$1" in
    *.test.sh|*_test.sh|test_*|tests/*|*/tests/*|test/*|*/test/*) return 0 ;;
  esac
  return 1
}

# A mechanism is billed only for a verifiable caller: a workflow job step
# that names its path directly, or a header that says by hand and why. The
# bin/tests/*.test.sh glob never spells a script's own path, so a plain
# grep for that path already lands outside the glob loop -- a script whose
# only runner is "its test ran in CI" (the #116 case) matches neither and
# is not charged.
workflow_invokes() { # <path>
  local wf
  for wf in "$REPO"/.github/workflows/*.yml "$REPO"/.github/workflows/*.yaml; do
    [ -f "$wf" ] || continue
    grep -Fq "$1" "$wf" && return 0
  done
  return 1
}

runner_declared_by_hand() { # <path>
  local line reason
  line="$(grep -m1 '^# RUNNER:' "$REPO/$1" 2>/dev/null)" || return 1
  case "$line" in
    '# RUNNER: by hand -- '*) ;;
    *) return 1 ;;
  esac
  reason="${line#*by hand -- }"
  reason="$(printf '%s' "$reason" | tr -d '[:space:]')"
  [ -n "$reason" ]
}

is_mechanism() { # <mode> <path>
  is_test "$2" && return 1
  case "$2" in .github/workflows/*.yml|.github/workflows/*.yaml) return 0 ;; esac
  [ "$1" = 100755 ] || return 1
  workflow_invokes "$2" && return 0
  runner_declared_by_hand "$2" && return 0
  return 1
}

# Everything is_mechanism refuses for lack of a caller is a mechanism-budget
# non-event -- it costs nothing, so nothing else ever looks at it again. A
# workflow file needs no caller of its own (GitHub triggers it) and a test is
# exercised by the suite glob by design; every OTHER executable under the
# index is a built tool, and etalon#127 is what happens when one of those sits
# uncalled: two days unnoticed, discovered only because a budget check (not
# this one) flagged its removal.
is_unwired_candidate() { # <mode> <path> -> 0 if a caller is owed and absent
  is_test "$2" && return 1
  case "$2" in .github/workflows/*.yml|.github/workflows/*.yaml) return 1 ;; esac
  [ "$1" = 100755 ] || return 1
  return 0
}

LIST="$(git -C "$REPO" ls-files -s)" || dieblind "cannot read the index of $REPO"
[ -n "$LIST" ] || dieblind "no tracked files in $REPO -- refusing to report a count I did not measure"

now=0
mechs=''
unwired=''
while read -r mode _sha _stage path; do
  [ -n "${path:-}" ] || continue
  if is_mechanism "$mode" "$path"; then
    now=$((now + 1))
    mechs="$mechs$path"$'\n'
  elif is_unwired_candidate "$mode" "$path"; then
    unwired="$unwired$path"$'\n'
  fi
done <<EOF
$LIST
EOF

if [ "$UNWIRED" -eq 1 ]; then
  count="$(printf '%s' "$unwired" | grep -c .)"
  printf 'mechanism-budget --unwired -- %s executable(s) under %s name no verified caller\n' \
    "$count" "$REPO"
  if [ "$count" -gt 0 ]; then
    printf '  FLAG [mechanism-budget] built but not wired: nothing calls these, and\n'
    printf '        nothing would report it missing (etalon#127).\n'
    printf '%s' "$unwired" | sed 's/^/          /'
    printf '        Name a caller: a literal path in a .github/workflows/*.yml job step,\n'
    printf '        or a header line %s on the script itself.\n' "'# RUNNER: by hand -- <reason>'"
    exit "$EXIT_FINDING"
  fi
  printf '  ok -- every executable names a caller.\n'
  exit "$EXIT_OK"
fi

if [ "$ACCEPT" -eq 1 ]; then
  if [ -f "$RATCHET" ]; then
    prev="$(grep -v '^#' "$RATCHET" | tr -d '[:space:]')"
    case "$prev" in ''|*[!0-9]*) prev='' ;; esac
    if [ -n "$prev" ] && [ "$now" -gt "$prev" ]; then
      printf 'mechanism-budget --accept -- REFUSED. The repo carries %d mechanism(s) MORE\n' "$((now - prev))" >&2
      printf '  than the baseline of %s, and this ratchet only falls. Retire two.\n' "$prev" >&2
      exit "$EXIT_FINDING"
    fi
  fi
  untracked="$(git -C "$REPO" ls-files --others --exclude-standard | grep -c .)"
  [ "${untracked:-0}" -gt 0 ] && \
    printf 'mechanism-budget --accept -- WARNING: %s untracked file(s) are NOT in this baseline. Stage them and re-run.\n' "$untracked" >&2
  printf '# mechanism-ratchet -- mechanisms in this repo. SHRINKS ONLY.\n# Written by mechanism-budget.sh --accept, which refuses to raise it.\n# accepted %s\n%s\n' \
    "$(date -Is)" "$now" > "$RATCHET" || dieblind "cannot write $RATCHET"
  printf 'mechanism-budget --accept -- baseline is now %s mechanism(s).\n' "$now"
  exit "$EXIT_OK"
fi

[ -f "$RATCHET" ] || dieblind "no ratchet at $RATCHET -- run --accept to seed it. A missing baseline is not a pass."
was="$(grep -v '^#' "$RATCHET" | tr -d '[:space:]')"
case "$was" in ''|*[!0-9]*) die2 "unreadable baseline in $RATCHET: '$was'" ;; esac

printf 'mechanism-budget -- %s mechanism(s) in %s, baseline %s, delta %+d\n' \
  "$now" "$REPO" "$was" "$((now - was))"

if [ "$now" -gt "$was" ]; then
  printf '  FLAG [mechanism-budget] this repo adds %d mechanism(s) over the baseline.\n' "$((now - was))"
  printf '        A new mechanism costs two retirements. The ratchet only falls, and\n'
  printf '        raising %s is rejected too.\n' "$RATCHET"
  printf '        mechanisms counted:\n'
  printf '%s' "$mechs" | sed 's/^/          /'
  exit "$EXIT_FINDING"
fi
[ "$now" -lt "$was" ] && printf '  %d retirement(s) below the baseline -- run --accept to lock it in.\n' "$((was - now))"
printf '  ok -- at or under the baseline.\n'
exit "$EXIT_OK"
