#!/usr/bin/env bash
# state-prose-lint.sh -- prose that describes state, not mechanism.
# RUNNER: .github/workflows/tests.yml
# GUARD-TEST: bin/tests/state-prose-lint.test.sh
#
# TRAPS: an invariant is a rule, not a state description -- precision over
# recall, or the findings get ignored wholesale. A NUL-separated file list
# cannot survive a command substitution. Seeding before `git add` reads an
# unstaged file as absent and lands the baseline too low.

set -uo pipefail

CLI_NAME='state-prose-lint.sh'
CLI_SUMMARY='does this tree describe its own state where it should encode a mechanism?'
CLI_USAGE='  state-prose-lint.sh           census the TREE against bin/state-prose.ratchet
  state-prose-lint.sh --accept  record the current tree count as the baseline
  state-prose-lint.sh --causal  read TEXT on stdin (an issue/PR body), flag an
                                 unwitnessed causal claim. Report-only: a
                                 caller gating on this should warn, not deny
                                 (etalon#20). No ratchet, no tree.
  state-prose-lint.sh --predicate
                                 read TEXT on stdin (an issue/PR body), flag a
                                 bare measured figure with no adjacent command
                                 or citation AND timestamp of when it was
                                 fetched. Report-only, same stance as --causal
                                 (etalon#141). No ratchet, no tree.
  state-prose-lint.sh --api OWNER/REPO
                                 census OWNER/REPOs milestone and label
                                 descriptions via the GitHub API against
                                 bin/state-prose-api.ratchet -- API objects
                                 are not in a git tree, so they carry their
                                 own ratchet (etalon#137).
  state-prose-lint.sh --api OWNER/REPO --accept
                                 record that census as the baseline'
CLI_FLAGS='--accept --causal --predicate --api'
CLI_EXITS='  0  the tree was read and it is at or under the baseline, or --causal/--predicate found nothing
  1  over the baseline, --accept was asked to raise it, or --causal/--predicate found an unwitnessed claim
  2  usage error, or an unreadable baseline
  6  BLIND: not a repository, the census could not read the tree, or --api
     could not read OWNER/REPOs milestones or labels from the API'
CLI_POSITIONAL=any
. "$(dirname "${BASH_SOURCE[0]}")/lib/cli-guard.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib/exit-codes.sh"
cli_guard "$@"

die2()    { printf '%s: %s\n' "$CLI_NAME" "$*" >&2; exit "$EXIT_USAGE"; }
dieblind(){ printf '%s: BLIND -- %s\n' "$CLI_NAME" "$*" >&2; exit "$EXIT_BLIND"; }

# --causal reads a body of TEXT (not a git tree -- an issue/PR body has no
# merge base to re-baseline against), so it runs before any git check and
# carries no ratchet. etalon#20: a causal connective ("because", "is why", ...)
# with no witness (a fenced/indented command, a backtick span, a run URL, a
# file:line citation) in the same or an adjacent paragraph is unwitnessed.
# Adjacent means a small window either side, not same-paragraph-only:
# etalon#20's own specimens state the claim, then a "Disproving command, in
# full:" label, then the witness, each its own paragraph -- and #4's
# precision-over-recall stance means a wide-but-wrong witness match is cheaper
# than a narrative paragraph flagged for a witness just out of reach.
CAUSAL_AWK='
function flushpara() {
  if (buf_nonblank) { n++; P[n] = para }
  para = ""; buf_nonblank = 0
}
{
  if ($0 == "") { flushpara(); next }
  buf_nonblank = 1
  if (para == "") para = $0; else para = para "\n" $0
}
END {
  flushpara()
  for (i = 1; i <= n; i++) {
    low = tolower(P[i])
    C[i] = (low ~ /(^|[^a-z])(because|caused|is why|so that|due to|the cause is|which is why|therefore)([^a-z]|$)/)
    W[i] = (P[i] ~ /```/) || (P[i] ~ /`[^`]+`/) || (low ~ /https?:\/\//) \
        || (P[i] ~ /[A-Za-z0-9_.\/-]+\.[a-z]+:[0-9]+/) || (P[i] ~ /(^|\n)[ \t][ \t][ \t][ \t]/)
  }
  findings = 0
  for (i = 1; i <= n; i++) {
    if (!C[i]) continue
    witnessed = 0
    for (j = i - 2; j <= i + 2; j++) { if (j >= 1 && j <= n && W[j]) witnessed = 1 }
    if (witnessed) continue
    flat = P[i]; gsub(/\n/, " / ", flat)
    printf "UNWITNESSED: %s\n", substr(flat, 1, 160)
    findings++
  }
  printf "PARAGRAPHS %d\n", n
  printf "FINDINGS %d\n", findings
}
'

if [ "${1:-}" = --causal ]; then
  CAUSAL_OUT="$(awk "$CAUSAL_AWK")" || dieblind "could not scan stdin"
  CAUSAL_PARAS="$(printf '%s\n' "$CAUSAL_OUT" | sed -n 's/^PARAGRAPHS //p')"
  CAUSAL_FOUND="$(printf '%s\n' "$CAUSAL_OUT" | sed -n 's/^FINDINGS //p')"
  case "$CAUSAL_FOUND" in ''|*[!0-9]*) dieblind "the causal scan produced no finding count" ;; esac
  printf 'state-prose-lint --causal -- %s unwitnessed causal claim(s) of %s paragraph(s) considered\n' \
    "$CAUSAL_FOUND" "$CAUSAL_PARAS"
  printf '%s\n' "$CAUSAL_OUT" | grep '^UNWITNESSED: ' | sed 's/^/  /'
  if [ "$CAUSAL_FOUND" -gt 0 ]; then
    printf '  FLAG [causal] a causal claim with no adjacent witness. Report-only: this\n'
    printf '        does not deny on its own (etalon#20) -- attach the command, citation,\n'
    printf '        or run URL that was checked before writing it.\n'
    exit "$EXIT_FINDING"
  fi
  exit "$EXIT_OK"
fi

# --predicate reads TEXT on stdin like --causal (no tree, no ratchet -- an
# issue/PR body has no merge base). etalon#141: a bare measured figure (a
# number, a percentage, a ratio, or a number word, outside narrative filler)
# is a staleness risk -- it can only be re-verified by re-running whatever
# produced it. This extends --causal's witness grammar (command, backtick
# span, run URL, file:line citation) with a timestamp requirement, since
# staleness and not provenance is what this mode exists to catch: a witness
# needs BOTH a command/citation AND a nearby timestamp, either alone is not
# enough (wavebucks quoted a 173-word median read off an archive that was
# since replaced, with nothing recording that the number ever needed
# re-checking).
PREDICATE_AWK='
function flushpara() {
  if (buf_nonblank) { n++; P[n] = para }
  para = ""; buf_nonblank = 0
}
BEGIN {
  QTY = "(^|[^a-z0-9_-])(two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|hundred|[0-9]+)[ -]([a-z][a-z-]*[ -])?([a-z][a-z-]*[ -])?[a-z][a-z-]*s([^a-z]|$)"
  QTY_STOP = "(^|[^a-z])(is|was|has|as|this|thus|its|us|does|goes|less|else|yes|plus|across|unless|always|versus|status|series|means|says|gives|takes|makes|needs|reads|writes|exists|runs|does|its)([^a-z]|$)"
  PCT = "(^|[^a-z0-9_-])[0-9]+(\\.[0-9]+)?%([^a-z0-9]|$)"
  RATIO = "(^|[^a-z0-9_-])[0-9]+(/[0-9]+)+([^a-z0-9]|$)"
  FILLER = "exactly|by construction|at most|at least|no more than|invariant|(^| )(must|never|always|only|per|each|any|every)( |$)"
}
{
  if ($0 == "") { flushpara(); next }
  buf_nonblank = 1
  if (para == "") para = $0; else para = para "\n" $0
}
END {
  flushpara()
  for (i = 1; i <= n; i++) {
    low = tolower(P[i])
    isqty = (low ~ QTY && low !~ QTY_STOP) || (low ~ PCT) || (low ~ RATIO)
    C[i] = isqty && low !~ FILLER
    CMD[i] = (P[i] ~ /```/) || (P[i] ~ /`[^`]+`/) || (low ~ /https?:\/\//) \
        || (P[i] ~ /[A-Za-z0-9_.\/-]+\.[a-z]+:[0-9]+/) || (P[i] ~ /(^|\n)[ \t][ \t][ \t][ \t]/)
    TS[i] = (low ~ /(^|[^0-9])(19|20)[0-9][0-9]-[0-9][0-9]-[0-9][0-9]([^0-9]|$)/) || (low ~ /(^| )as of( |$)/) \
        || (low ~ /(^| )(fetched|retrieved)( |$)/)
  }
  findings = 0
  for (i = 1; i <= n; i++) {
    if (!C[i]) continue
    has_cmd = 0; has_ts = 0
    for (j = i - 2; j <= i + 2; j++) { if (j >= 1 && j <= n) { if (CMD[j]) has_cmd = 1; if (TS[j]) has_ts = 1 } }
    if (has_cmd && has_ts) continue
    flat = P[i]; gsub(/\n/, " / ", flat)
    printf "UNWITNESSED: %s\n", substr(flat, 1, 160)
    findings++
  }
  printf "PARAGRAPHS %d\n", n
  printf "FINDINGS %d\n", findings
}
'

if [ "${1:-}" = --predicate ]; then
  PREDICATE_OUT="$(awk "$PREDICATE_AWK")" || dieblind "could not scan stdin"
  PREDICATE_PARAS="$(printf '%s\n' "$PREDICATE_OUT" | sed -n 's/^PARAGRAPHS //p')"
  PREDICATE_FOUND="$(printf '%s\n' "$PREDICATE_OUT" | sed -n 's/^FINDINGS //p')"
  case "$PREDICATE_FOUND" in ''|*[!0-9]*) dieblind "the predicate scan produced no finding count" ;; esac
  printf 'state-prose-lint --predicate -- %s unwitnessed measured figure(s) of %s paragraph(s) considered\n' \
    "$PREDICATE_FOUND" "$PREDICATE_PARAS"
  printf '%s\n' "$PREDICATE_OUT" | grep '^UNWITNESSED: ' | sed 's/^/  /'
  if [ "$PREDICATE_FOUND" -gt 0 ]; then
    printf '  FLAG [predicate] a measured figure with no adjacent command/citation AND\n'
    printf '        timestamp of when it was fetched. Report-only: this does not deny on its own\n'
    printf '        (etalon#141) -- attach the command or citation, and when it ran.\n'
    exit "$EXIT_FINDING"
  fi
  exit "$EXIT_OK"
fi

# --api censuses GitHub API objects (milestone/label descriptions), which
# live outside any git tree and so cannot share state-prose.ratchet's
# baseline -- etalon#137. STATE_PROSE_GH lets a test point this at a stub
# instead of the real `gh`, the same seam --causal and the tree scan have
# via STATE_PROSE_RATCHET.
API_SCAN_AWK='
BEGIN {
  FS = "\t"
  QTY = "(^|[^a-z0-9_-])(two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|hundred|[0-9]+)[ -]([a-z][a-z-]*[ -])?([a-z][a-z-]*[ -])?[a-z][a-z-]*s([^a-z]|$)"
  QTY_STOP = "(^|[^a-z])(is|was|has|as|this|thus|its|us|does|goes|less|else|yes|plus|across|unless|always|versus|status|series|means|says|gives|takes|makes|needs|reads|writes|exists|runs|does|its)([^a-z]|$)"
}
{
  if (kind != $1 || name != $2) fence = 0
  kind = $1; name = $2
  line = $3
  sub(/^[ \t]+/, "", line)
  if (line == "") next
  if (line ~ /^```/) { fence = !fence; next }
  if (fence) next
  considered++
  s = tolower(line)
  if (s ~ /(https?:\/\/|shellcheck |[$][{(])/) next
  if (s ~ /exactly|by construction|at most|at least|no more than|invariant|(^| )(must|never|always|only|per|each|any|every)( |$)/) next
  hit = ""
  if (s ~ /(^|[^0-9])(19|20)[0-9][0-9]-[0-9][0-9]-[0-9][0-9]([^0-9]|$)/) hit = "date"
  else if (s ~ /(^| )as of( |$)/) hit = "as-of"
  else if (s ~ QTY && s !~ QTY_STOP) hit = "count"
  if (hit == "") next
  printf "%s:%s: [%s] %s\n", kind, name, hit, substr(line, 1, 90)
}
END { printf "CONSIDERED %d\n", considered + 0 }
'

if [ "${1:-}" = --api ]; then
  shift
  API_REPO="${1:-}"
  case "$API_REPO" in
    */*) shift ;;
    *) die2 "--api needs an OWNER/REPO argument" ;;
  esac
  API_ACCEPT=0
  case "${1:-}" in
    --accept) API_ACCEPT=1; shift ;;
    '') ;;
    *) die2 "unexpected argument: $1" ;;
  esac

  GH_BIN="${STATE_PROSE_GH:-gh}"
  api_get() { "$GH_BIN" api "repos/$API_REPO/$1" --paginate 2>/dev/null; } # <endpoint>

  # jq on empty input runs the filter zero times and -e then exits 0 (no
  # output was ever false/null), so a silently-failed `gh` whose stdout is
  # empty would read as success: the fetch's own exit status is checked
  # first, and the content second.
  is_json_array() { # <text>
    [ -n "$1" ] || return 1
    printf '%s' "$1" | jq -e 'type == "array"' >/dev/null 2>&1
  }

  MILESTONES_JSON="$(api_get milestones)"; ms_rc=$?
  if [ "$ms_rc" -ne 0 ] || ! is_json_array "$MILESTONES_JSON"; then
    dieblind "could not read repos/$API_REPO/milestones from the API"
  fi
  LABELS_JSON="$(api_get labels)"; lb_rc=$?
  if [ "$lb_rc" -ne 0 ] || ! is_json_array "$LABELS_JSON"; then
    dieblind "could not read repos/$API_REPO/labels from the API"
  fi

  API_STREAM="$( {
    printf '%s' "$MILESTONES_JSON" | jq -r '.[] | ["milestone", .title, ((.description // "") | split("\n")[])] | @tsv'
    printf '%s' "$LABELS_JSON" | jq -r '.[] | ["label", .name, ((.description // "") | split("\n")[])] | @tsv'
  } )" || dieblind "could not read titles/names/descriptions from the API response"

  API_REPORT="$(printf '%s\n' "$API_STREAM" | awk "$API_SCAN_AWK")" || dieblind "the API census could not scan the descriptions"
  API_CONSIDERED="$(printf '%s\n' "$API_REPORT" | sed -n 's/^CONSIDERED //p')"
  case "$API_CONSIDERED" in ''|*[!0-9]*) dieblind "the API census produced no line count" ;; esac
  API_FINDINGS="$(printf '%s\n' "$API_REPORT" | grep -v '^CONSIDERED ' | grep -c .)"

  API_RATCHET="${STATE_PROSE_API_RATCHET:-$(dirname "${BASH_SOURCE[0]}")/state-prose-api.ratchet}"

  if [ "$API_ACCEPT" -eq 1 ]; then
    if [ -f "$API_RATCHET" ]; then
      prev="$(grep -v '^#' "$API_RATCHET" | tr -d '[:space:]')"
      case "$prev" in ''|*[!0-9]*) prev='' ;; esac
      if [ -n "$prev" ] && [ "$API_FINDINGS" -gt "$prev" ]; then
        printf 'state-prose-lint --api --accept -- REFUSED. %s is %d line(s) ABOVE the\n' "$API_REPO" "$((API_FINDINGS - prev))" >&2
        printf '  baseline of %s, and this ratchet only falls. Edit the description instead.\n' "$prev" >&2
        exit "$EXIT_FINDING"
      fi
    fi
    printf '# state-prose-api.ratchet -- state-describing lines in %s milestone/label descriptions. SHRINKS ONLY.\n# Written by state-prose-lint.sh --api %s --accept, which refuses to raise it.\n# accepted %s\n%s\n' \
      "$API_REPO" "$API_REPO" "$(date -Is)" "$API_FINDINGS" > "$API_RATCHET" || dieblind "cannot write $API_RATCHET"
    printf 'state-prose-lint --api %s --accept -- baseline is now %s line(s).\n' "$API_REPO" "$API_FINDINGS"
    exit "$EXIT_OK"
  fi

  [ -f "$API_RATCHET" ] || dieblind "no ratchet at $API_RATCHET -- run --api $API_REPO --accept to seed it. A missing baseline is not a pass."
  was="$(grep -v '^#' "$API_RATCHET" | tr -d '[:space:]')"
  case "$was" in ''|*[!0-9]*) die2 "unreadable baseline in $API_RATCHET: '$was'" ;; esac

  printf 'state-prose-lint --api %s -- %s state-describing line(s) of %s considered, baseline %s\n' \
    "$API_REPO" "$API_FINDINGS" "$API_CONSIDERED" "$was"
  printf '%s\n' "$API_REPORT" | grep -v '^CONSIDERED ' | grep . | sed 's/^/  /'

  if [ "$API_FINDINGS" -gt "$was" ]; then
    printf '  FLAG [state-prose-api] %s gained %d state-describing line(s) over the\n' "$API_REPO" "$((API_FINDINGS - was))"
    printf '        baseline of %s in its milestone/label descriptions. The ratchet only\n' "$was"
    printf '        falls, and raising %s is rejected too.\n' "$API_RATCHET"
    exit "$EXIT_FINDING"
  fi
  [ "$API_FINDINGS" -lt "$was" ] && printf '  %d line(s) below the baseline -- run --api %s --accept to lock it in.\n' "$((was - API_FINDINGS))" "$API_REPO"
  printf '  ok -- at or under the baseline.\n'
  exit "$EXIT_OK"
fi

# CLI_POSITIONAL=any (above) exists so --api's OWNER/REPO argument clears
# cli_guard -- it does not mean a stray positional is quietly allowed here
# too. Without this, "state-prose-lint.sh some-typo" would fall through to a
# full, unflagged tree census: the exact silent-full-run trap bin/lib/cli-
# guard.sh's own header warns about.
case "${1:-}" in
  ''|--accept) ;;
  *) die2 "unexpected argument: $1" ;;
esac

RATCHET="${STATE_PROSE_RATCHET:-$(dirname "${BASH_SOURCE[0]}")/state-prose.ratchet}"

SCAN_AWK='
BEGIN {
  # ([a-z][a-z-]*[ -]){0,2} used a POSIX interval expression. mawk, the
  # awk this script runs under here (readlink -f $(which awk)), does not
  # implement intervals: it matches false silently rather than erroring,
  # so QTY missed a counted plural separated from its number by one or
  # more intervening words. The optional groups below, written out
  # explicitly rather than as a POSIX interval, are the portable fix.
  QTY = "(^|[^a-z0-9_-])(two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|hundred|[0-9]+)[ -]([a-z][a-z-]*[ -])?([a-z][a-z-]*[ -])?[a-z][a-z-]*s([^a-z]|$)"
  QTY_STOP = "(^|[^a-z])(is|was|has|as|this|thus|its|us|does|goes|less|else|yes|plus|across|unless|always|versus|status|series|means|says|gives|takes|makes|needs|reads|writes|exists|runs|does|its)([^a-z]|$)"
}
function lang(f) {
  if (f ~ /\.(md|markdown)$/)          return "m"
  if (f ~ /\.(sh|bash|conf|ya?ml|py)$/) return "h"
  if (f ~ /\.(mjs|js)$/)                return "j"
  return ""
}
# etalon#24: a state-carrying file need not have an extension (hf7y/scheduler
# ROSTER is the known instance) -- a shebang on line 1 is the content-sniff
# bin/lib/verb-set.sh already uses to answer "is this a verb".
FNR == 1 {
  L = lang(FILENAME)
  if (L == "" && ($0 ~ /^#!.*(\/|env )(ba)?sh([^a-z]|$)/ || $0 ~ /^#!.*(\/|env )python[0-9.]*([^a-z]|$)/)) L = "h"
  fence = 0
}
{
  if (L == "") next
  line = $0
  sub(/^[ \t]+/, "", line)
  if (line == "") next
  if (L == "m") {
    if (line ~ /^```/) { fence = !fence; next }
    if (fence) next
    if ($0 ~ /^(    |\t)/) next
    if (line ~ /^[|>]/) next
  } else if (L == "h") {
    if (line ~ /^#!/) next
    if (line !~ /^#/) next
    sub(/^#+[ \t]*/, "", line)
  } else {
    if (line !~ /^(\/\/|\/\*|\*)/) next
    sub(/^(\/\/+|\/\*+|\*+)[ \t]*/, "", line)
  }
  if (line == "") next
  n = split(line, w, /[ \t]+/)
  if (n < 4) next
  considered++
  s = tolower(line)
  if (s ~ /(https?:\/\/|shellcheck |[$][{(])/) next
  if (s ~ /exactly|by construction|at most|at least|no more than|invariant|(^| )(must|never|always|only|per|each|any|every)( |$)/) next
  hit = ""
  if (s ~ /(^|[^0-9])(19|20)[0-9][0-9]-[0-9][0-9]-[0-9][0-9]([^0-9]|$)/) hit = "date"
  else if (s ~ /(^| )as of( |$)/) hit = "as-of"
  else if (s ~ QTY && s !~ QTY_STOP) hit = "count"
  if (hit == "") next
  printf "%s:%d: [%s] %s\n", FILENAME, FNR, hit, substr(line, 1, 90)
}
END { printf "CONSIDERED %d\n", considered + 0 }
'

scan() { # reads NUL paths on stdin -> findings, then a CONSIDERED total
  local considered=0 out
  out="$(xargs -0 -r awk "$SCAN_AWK" 2>/dev/null)" || return 1
  while IFS= read -r l; do
    case "$l" in
      'CONSIDERED '*) considered=$((considered + ${l#CONSIDERED })) ;;
      '') ;;
      *) printf '%s\n' "$l" ;;
    esac
  done <<EOF
$out
EOF
  printf 'CONSIDERED %d\n' "$considered"
}

git rev-parse --git-dir >/dev/null 2>&1 || dieblind "not inside a git repository"

NFILES="$(git ls-files | grep -c .)" || dieblind "cannot list tracked files"
[ "${NFILES:-0}" -gt 0 ] || dieblind "no tracked files -- refusing to report a clean tree I did not read"

REPORT="$(git ls-files -z | grep -zv '^canon/' | scan)" || dieblind "the scan could not read the tree"
CONSIDERED="$(printf '%s\n' "$REPORT" | sed -n 's/^CONSIDERED //p')"
case "$CONSIDERED" in ''|*[!0-9]*) dieblind "the scan produced no line count" ;; esac
FINDINGS="$(printf '%s\n' "$REPORT" | grep -v '^CONSIDERED ' | grep -c . )"

if [ "${1:-}" = --accept ]; then
  if [ -f "$RATCHET" ]; then
    prev="$(grep -v '^#' "$RATCHET" | tr -d '[:space:]')"
    case "$prev" in ''|*[!0-9]*) prev='' ;; esac
    if [ -n "$prev" ] && [ "$FINDINGS" -gt "$prev" ]; then
      printf 'state-prose-lint --accept -- REFUSED. The tree is %d line(s) ABOVE the\n' "$((FINDINGS - prev))" >&2
      printf '  baseline of %s, and this ratchet only falls. Delete state prose instead.\n' "$prev" >&2
      exit "$EXIT_FINDING"
    fi
  fi
  untracked="$(git ls-files --others --exclude-standard | grep -c -E '\.(md|markdown|sh|bash|conf|ya?ml|py|mjs|js)$')"
  [ "${untracked:-0}" -gt 0 ] && \
    printf 'state-prose-lint --accept -- WARNING: %s scannable file(s) are UNTRACKED and NOT in this baseline. Stage them and re-run.\n' "$untracked" >&2
  printf '# state-prose.ratchet -- state-describing prose lines. SHRINKS ONLY.\n# Written by state-prose-lint.sh --accept, which refuses to raise it.\n# accepted %s\n%s\n' \
    "$(date -Is)" "$FINDINGS" > "$RATCHET" || dieblind "cannot write $RATCHET"
  printf 'state-prose-lint --accept -- baseline is now %s line(s).\n' "$FINDINGS"
  exit "$EXIT_OK"
fi

[ -f "$RATCHET" ] || dieblind "no ratchet at $RATCHET -- run --accept to seed it. A missing baseline is not a pass."
was="$(grep -v '^#' "$RATCHET" | tr -d '[:space:]')"
case "$was" in ''|*[!0-9]*) die2 "unreadable baseline in $RATCHET: '$was'" ;; esac

printf 'state-prose-lint -- %s state-describing line(s) of %s considered, baseline %s\n' \
  "$FINDINGS" "$CONSIDERED" "$was"
printf '%s\n' "$REPORT" | grep -v '^CONSIDERED ' | grep . | sed 's/^/  /'

if [ "$FINDINGS" -gt "$was" ]; then
  printf '  FLAG [state-prose] the tree gained %d state-describing line(s) over the\n' "$((FINDINGS - was))"
  printf '        baseline of %s. The ratchet only falls, and raising %s\n' "$was" "$RATCHET"
  printf '        is rejected too. A description of state is deleted on sight; encode\n'
  printf '        the mechanism, or state the invariant instead.\n'
  exit "$EXIT_FINDING"
fi
[ "$FINDINGS" -lt "$was" ] && printf '  %d line(s) below the baseline -- run --accept to lock it in.\n' "$((was - FINDINGS))"
printf '  ok -- at or under the baseline.\n'
exit "$EXIT_OK"
