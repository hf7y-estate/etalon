#!/usr/bin/env bash
# credential-wire-check.sh -- is THIS account's git push credential the
# fleet's shared token, or the App?
#
# RUNNER: bin/tests/credential-wire-check.test.sh only, via
# .github/workflows/tests.yml's suites job -- NOT wired into guard.yml. This
# guard reads a live account's OWN git config, not a checked-out repo's tree,
# so it cannot run the way etalon's other three guards do (checkout-only, no
# credential, no host). It is meant to run WHERE the account lives -- a
# self-dev's own health-check tick, or by hand -- with the verb `demande`
# already on PATH there. See the PR that added this file for what is and is
# not yet verified about that wiring.
#
# GUARD-TEST: bin/tests/credential-wire-check.test.sh
#
# PORTED FROM hf7y/realisateur#1134 (bin/selfdev-credentials.sh, deleted
# there 2026-09-08): the one check judged worth keeping out of a ~480-line
# fleet-wide audit that ran on no schedule -- pem/conf placement and
# deploy-key symmetry stayed behind; only the git-credential-helper
# classification survives, because that is the one finding that sat
# correct-and-unread for weeks. On a FLAG this escalates via `demande ask`
# (crt's WhatsApp relay to a human) instead of printing into a terminal
# nobody is at, which was the whole defect: the check was right and nobody
# heard it.
#
# TRAPS: NEVER FATAL on the escalation step. A recovery that aborts because
#   it could not announce itself is worse than one that stays silent about
#   the announcement but still reports the underlying finding -- zaxon.sh's
#   own rule (realisateur bin/lib/zaxon.sh), carried here because `demande`
#   can legitimately be absent (this script may run somewhere it is not
#   installed) or BLIND (the relay unreachable), and neither should turn a
#   real credential finding into a crash.

set -uo pipefail

CLI_NAME='credential-wire-check.sh'
CLI_SUMMARY='does this account push as the fleet App, or still on the shared gho_ token?'
CLI_USAGE='  credential-wire-check.sh --account <name>
      classify the CURRENT git global credential.https://github.com.helper
  credential-wire-check.sh --account <name> --helper <value>
      classify <value> instead of reading it live (also how the suite runs this)'
CLI_FLAGS='--account --helper'
CLI_POSITIONAL=any
CLI_EXITS='  0  wired to the App -- no finding
  1  drift found (still on the shared token, no helper, or undecidable) -- escalation attempted, never fatal on its own failure
  2  usage error
  6  BLIND: --account was not given, or git is not on PATH to read the live config'
. "$(dirname "${BASH_SOURCE[0]}")/lib/cli-guard.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib/exit-codes.sh"
cli_guard "$@"

die2()    { printf '%s: %s\n' "$CLI_NAME" "$*" >&2; exit "$EXIT_USAGE"; }
dieblind(){ printf '%s: BLIND -- %s\n' "$CLI_NAME" "$*" >&2; exit "$EXIT_BLIND"; }

ACCOUNT=""
HELPER_GIVEN=0
HELPER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --account) [ $# -ge 2 ] || die2 "--account needs a name"; ACCOUNT="$2"; shift 2 ;;
    --helper)  [ $# -ge 2 ] || die2 "--helper needs a value"; HELPER="$2"; HELPER_GIVEN=1; shift 2 ;;
    *) die2 "unexpected argument: $1" ;;
  esac
done
[ -n "$ACCOUNT" ] || dieblind "no --account given -- refusing to escalate or report for an unnamed account"

if [ "$HELPER_GIVEN" -eq 0 ]; then
  command -v git >/dev/null 2>&1 || dieblind "git is not on PATH; cannot read the credential helper"
  HELPER="$(git config --global --get-all credential."https://github.com".helper 2>/dev/null)"
fi

# Same classification bin/selfdev-credentials.sh used (its "WIRED" comment,
# realisateur#171): the helper's SHAPE, not url.insteadOf, which counts zero.
n="$(printf '%s' "$HELPER" | grep -c .)"
case "$n" in
  0) wire=none ;;
  1) case "$HELPER" in
       *selfdev-gh-app.sh*)         wire=app ;;
       *"gh auth git-credential"*)  wire=gh ;;
       *)                           wire=other ;;
     esac ;;
  *) wire=multi ;;
esac

# demande_escalate <reason> -- ask a human, never fatal either way. Prints
# what happened so the caller's own log/report still names the finding even
# when nothing answered.
demande_escalate() {
  local reason="$1" out rc
  if ! command -v demande >/dev/null 2>&1; then
    printf '  ESCALATION SKIPPED -- demande is not on PATH here; report by hand: %s\n' "$reason" >&2
    return 0
  fi
  out="$(demande ask "credential-wire-check: $ACCOUNT -- $reason" credential-wire-check)"; rc=$?
  case "$rc" in
    0) printf '  ESCALATED via demande -- ticket %s (poll: demande check %s)\n' "$out" "$out" ;;
    6) printf '  ESCALATION BLIND -- no demande relay answered; report by hand: %s\n' "$reason" >&2 ;;
    *) printf '  ESCALATION FAILED (demande exit %s); report by hand: %s\n' "$rc" "$reason" >&2 ;;
  esac
  return 0
}

case "$wire" in
  app)
    printf '%s: %s -- ok, wired to the App.\n' "$CLI_NAME" "$ACCOUNT"
    exit "$EXIT_OK"
    ;;
  none)
    reason="no git credential helper -- https pushes have no credential at all"
    ;;
  gh)
    reason="git credential helper is still \`gh auth git-credential\`, i.e. the shared gho_ token -- run selfdev-gh-app.sh --wire"
    ;;
  multi)
    reason="credential.https://github.com.helper holds MORE THAN ONE value -- git takes the first that answers, so which credential pushes is not decidable from config"
    ;;
  *)
    reason="git credential helper is '$wire', not the App"
    ;;
esac

printf '%s: %s -- FLAG: %s\n' "$CLI_NAME" "$ACCOUNT" "$reason"
demande_escalate "$reason"
exit "$EXIT_FINDING"
