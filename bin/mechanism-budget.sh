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
  mechanism-budget.sh --repo <dir> --accept   record the count as the baseline'
CLI_FLAGS='--repo --accept'
CLI_EXITS='  0  the repo was read and it is at or under the baseline
  1  over the baseline (a net add), or --accept was asked to raise it
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
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) [ $# -ge 2 ] || die2 "--repo needs a directory"; REPO="$2"; shift 2 ;;
    --accept) ACCEPT=1; shift ;;
    *) die2 "unexpected argument: $1" ;;
  esac
done
[ -d "$REPO" ] || dieblind "no such directory: $REPO"
REPO="$(cd "$REPO" && pwd)" || dieblind "cannot enter $REPO"
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || dieblind "$REPO is not a git repository"

RATCHET="${MECHANISM_BUDGET_RATCHET:-$REPO/.mechanism-ratchet}"
TRANSFERS="${MECHANISM_BUDGET_TRANSFERS:-$REPO/.mechanism-transfers}"

is_test() {
  case "$1" in
    *.test.sh|*_test.sh|test_*|tests/*|*/tests/*|test/*|*/test/*) return 0 ;;
  esac
  return 1
}

is_mechanism() { # <mode> <path>
  is_test "$2" && return 1
  case "$2" in .github/workflows/*.yml|.github/workflows/*.yaml) return 0 ;; esac
  [ "$1" = 100755 ] && return 0
  return 1
}

LIST="$(git -C "$REPO" ls-files -s)" || dieblind "cannot read the index of $REPO"
[ -n "$LIST" ] || dieblind "no tracked files in $REPO -- refusing to report a count I did not measure"

now=0
mechs=''
while read -r mode _sha _stage path; do
  [ -n "${path:-}" ] || continue
  if is_mechanism "$mode" "$path"; then
    now=$((now + 1))
    mechs="$mechs$path"$'\n'
  fi
done <<EOF
$LIST
EOF

# A transfer is a mechanism RECEIVED from another estate repo, its removal
# there named in the ledger. It is estate-neutral -- the budget stops
# growth, not moves -- so it is credited against the ratchet, never billed
# as an organic add that must be paid for by retirements.
credit=0
credited=''
if [ -f "$TRANSFERS" ]; then
  while read -r mode _sha _stage path; do
    [ -n "${path:-}" ] || continue
    is_mechanism "$mode" "$path" || continue
    tpath="$(awk -v p="$path" '!/^[[:space:]]*#/ && $1==p {print $1; exit}' "$TRANSFERS")"
    if [ -n "$tpath" ]; then
      credit=$((credit + 1))
      credited="$credited$tpath"$'\n'
    fi
  done <<EOF
$LIST
EOF
fi

if [ "$ACCEPT" -eq 1 ]; then
  if [ -f "$RATCHET" ]; then
    prev="$(grep -v '^#' "$RATCHET" | tr -d '[:space:]')"
    case "$prev" in ''|*[!0-9]*) prev='' ;; esac
    if [ -n "$prev" ] && [ "$now" -gt "$((prev + credit))" ]; then
      printf 'mechanism-budget --accept -- REFUSED. The repo carries %d mechanism(s) MORE\n' "$((now - prev - credit))" >&2
      printf '  than the baseline of %s (after crediting %d transfer(s)), and this ratchet\n' "$prev" "$credit" >&2
      printf '  only falls. Retire two, or name the rest in %s.\n' "$TRANSFERS" >&2
      exit "$EXIT_FINDING"
    fi
    if [ -n "$prev" ] && [ "$now" -gt "$prev" ]; then
      printf 'mechanism-budget --accept -- folding in %d transferred mechanism(s).\n' "$((now - prev))"
    fi
  fi
  untracked="$(git -C "$REPO" ls-files --others --exclude-standard | grep -c .)"
  [ "${untracked:-0}" -gt 0 ] && \
    printf 'mechanism-budget --accept -- WARNING: %s untracked file(s) are NOT in this baseline. Stage them and re-run.\n' "$untracked" >&2
  printf '# mechanism-ratchet -- mechanisms in this repo. SHRINKS ONLY.\n# Written by mechanism-budget.sh --accept, which refuses to raise it.\n# accepted %s\n%s\n' \
    "$(date -Is)" "$now" > "$RATCHET" || dieblind "cannot write $RATCHET"
  if [ "$credit" -gt 0 ] && [ -f "$TRANSFERS" ]; then
    awk -v credited="$credited" '
      BEGIN { n = split(credited, want, "\n"); for (i = 1; i <= n; i++) if (want[i] != "") seen[want[i]] = 1 }
      /^[[:space:]]*#/ { print; next }
      { if (!($1 in seen)) print }
    ' "$TRANSFERS" > "$TRANSFERS.tmp" && mv "$TRANSFERS.tmp" "$TRANSFERS"
  fi
  printf 'mechanism-budget --accept -- baseline is now %s mechanism(s).\n' "$now"
  exit "$EXIT_OK"
fi

[ -f "$RATCHET" ] || dieblind "no ratchet at $RATCHET -- run --accept to seed it. A missing baseline is not a pass."
was="$(grep -v '^#' "$RATCHET" | tr -d '[:space:]')"
case "$was" in ''|*[!0-9]*) die2 "unreadable baseline in $RATCHET: '$was'" ;; esac

printf 'mechanism-budget -- %s mechanism(s) in %s, baseline %s, delta %+d\n' \
  "$now" "$REPO" "$was" "$((now - was))"
[ "$credit" -gt 0 ] && printf '  %d mechanism(s) credited as transfers-in (see %s)\n' "$credit" "$TRANSFERS"

organic=$((now - was - credit))
if [ "$organic" -gt 0 ]; then
  printf '  FLAG [mechanism-budget] this repo adds %d mechanism(s) over the baseline.\n' "$organic"
  printf '        A new mechanism costs two retirements. The ratchet only falls, and\n'
  printf '        raising %s is rejected too.\n' "$RATCHET"
  printf '        mechanisms counted:\n'
  printf '%s' "$mechs" | sed 's/^/          /'
  exit "$EXIT_FINDING"
fi
if [ "$now" -gt "$was" ]; then
  printf '  %d transfer(s) covered the rest -- run --accept to fold them into the baseline.\n' "$((now - was))"
elif [ "$now" -lt "$was" ]; then
  printf '  %d retirement(s) below the baseline -- run --accept to lock it in.\n' "$((was - now))"
fi
printf '  ok -- at or under the baseline.\n'
exit "$EXIT_OK"
