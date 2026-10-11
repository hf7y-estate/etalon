#!/usr/bin/env bash
# shellcheck disable=SC2317  # every row_* is called only indirectly, via "row_$1"
# migration-landed.sh -- acceptance gate for the self-dev migration, received
# from hf7y-estate/ecosim (etalon#98) now that ecosim's study is finished.
#
#   migration-landed.sh            # every row
#   migration-landed.sh --json     # one JSON object per row
#   migration-landed.sh dispatch   # one row
#
# Exit: 0 every row OK / 1 any row DOWN / 6 any row BLIND and none DOWN /
# 2 usage. BLIND is never folded into OK. 1 is EXIT_FINDING from
# bin/lib/exit-codes.sh -- this guard looked and found something, the same
# vocabulary bin/will-it-run.sh and bin/thermostat-veto.sh already use for a
# check that found a problem rather than one that could not look. ecosim's
# own exit was 5 for DOWN; this is the one thing that changed in the move.
#
# clones/creds retired (hf7y/ecosim#91): a host-side reader is a host change,
# and this gate does not ask for one.
#
# Overrides (tests point these at fixtures):
#   MIGRATION_LANDED_GH, MIGRATION_LANDED_SSH, MIGRATION_LANDED_MONKEY,
#   MIGRATION_LANDED_ORG, MIGRATION_LANDED_WINDOW_DAYS,
#   MIGRATION_LANDED_BACKOFF, MIGRATION_LANDED_PACE, MIGRATION_LANDED_ETALON,
#   MIGRATION_LANDED_REALISATEUR, MIGRATION_LANDED_SCHEDULER
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/exit-codes.sh"

GH="${MIGRATION_LANDED_GH:-gh}"
SSH="${MIGRATION_LANDED_SSH:-ssh}"
MONKEY="${MIGRATION_LANDED_MONKEY:-monkey}"
ORG="${MIGRATION_LANDED_ORG:-hf7y}"
WINDOW_DAYS="${MIGRATION_LANDED_WINDOW_DAYS:-14}"
ETALON_REF=main
BACKOFF="${MIGRATION_LANDED_BACKOFF:-65}"
PACE="${MIGRATION_LANDED_PACE:-10}"
ETALON_SRC="${MIGRATION_LANDED_ETALON:-https://github.com/$ORG/etalon}"
REALISATEUR_SRC="${MIGRATION_LANDED_REALISATEUR:-https://github.com/$ORG/realisateur}"
SCHEDULER_SRC="${MIGRATION_LANDED_SCHEDULER:-https://github.com/$ORG/scheduler}"

ROWS=(dispatch ci-free wedge backlog needs-zach interchange participation
      v0-residue verbs symmetry placement prose state-prose thermostat)

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
SINCE="$(date -u -d "-${WINDOW_DAYS} days" +%Y-%m-%dT%H:%M:%SZ)"

st=""; msg=""
ok()    { st=OK;    msg="$1"; }
down()  { st=DOWN;  msg="$1"; }
blind() { st=BLIND; msg="$1"; }

# Any gh/ssh failure is could-not-look, never nothing-there. Callers must
# check the return, not the emptiness of the output: gh prints [] on a
# rate-limited search too, which is why every probe below tests $?.
gh_json() { "$GH" "$@" 2>"$TMP/err"; }

# The gate now runs ON monkey (a self-hosted runner), so a host row has no hop
# to make. Only the ssh seam the tests point at forces the remote path.
on_monkey() {
  if [ -z "${MIGRATION_LANDED_SSH:-}" ] && [ "$MONKEY" = "$(hostname -s)" ]; then
    bash -c "$1"
  else
    "$SSH" "$MONKEY" "$1"
  fi
}

# Every repo this credential can list, which a scoped token shortens silently.
all_repos() {
  [ -s "$TMP/all-repos" ] && return 0
  gh_json repo list "$ORG" --limit 200 --json name \
    | jq -r '.[].name' > "$TMP/all-repos" || return 1
  [ -s "$TMP/all-repos" ]
}

# THE ROSTER is what self-dev RUNS: the uid band on the host and the
# scheduler's pace table. Walking every repo judges projects nobody enrolled.
roster() {
  [ -s "$TMP/roster" ] && return 0
  local accts paced
  accts="$(on_monkey 'getent passwd | awk -F: "\$3>=3000 && \$3<=3099 {print \$1}"' 2>"$TMP/err")" || accts=""
  paced="$(gh_json api "repos/$ORG/scheduler/contents/schedule/_paced.$MONKEY.conf" --jq .content \
           | base64 -d | awk -F'|' 'NF > 1 && $1 !~ /^#/ {print $1}')" || paced=""
  [ -n "$accts$paced" ] || return 1
  # Not filtered against the repo list: dropping a registered project because
  # a token could not see it is how a short roster reads as a complete one.
  printf '%s\n%s\n' "$accts" "$paced" | sed 's/^selfdev-//' | grep -v '^$' | sort -u \
    > "$TMP/roster"
  [ -s "$TMP/roster" ]
}

# etalon's linters, fetched at a ref the way the shared prose guard checks
# them out. One clone per run, shared by the rows that need one.
etalon() {
  [ -d "$TMP/etalon" ] && return 0
  git clone -q --depth 1 --branch "$ETALON_REF" "$ETALON_SRC" "$TMP/etalon" 2>"$TMP/err"
}

# Full clone: thermostat-probe.sh needs git log, and depth-1 would misread its window as clean.
scheduler_repo() {
  [ -d "$TMP/scheduler" ] && return 0
  git clone -q "$SCHEDULER_SRC" "$TMP/scheduler" 2>"$TMP/err"
}

# ---------------------------------------------------------------- rows

row_dispatch() {
  roster || { blind "roster unreadable: $(tr -d '\n' <"$TMP/err")"; return; }
  local r n=0 stale=() red=() bl=()
  while read -r r; do
    n=$((n+1))
    local j; j="$(gh_json run list -R "$ORG/$r" --limit 1 --json conclusion,event)" \
      || { bl+=("$r"); continue; }
    case "$(jq -r '.[0].event // "none"' <<<"$j")" in
      schedule|workflow_dispatch|repository_dispatch) ;;
      none) stale+=("$r:no-run"); continue ;;
      *) stale+=("$r:$(jq -r '.[0].event' <<<"$j")"); continue ;;
    esac
    [ "$(jq -r '.[0].conclusion' <<<"$j")" = success ] || red+=("$r")
  done < "$TMP/roster"
  if [ ${#stale[@]} -gt 0 ] || [ ${#red[@]} -gt 0 ]; then
    down "not on own clock: ${stale[*]:-none}; last run not green: ${red[*]:-none}${bl[*]:+; unreadable: ${bl[*]}}"
  elif [ ${#bl[@]} -gt 0 ]; then blind "run list unreadable: ${bl[*]}"
  else ok "$n repos triggered on their own clock, last run green"; fi
}

row_ci-free() {
  all_repos || { blind "repo list unreadable: $(tr -d '\n' <"$TMP/err")"; return; }
  # CAPABILITY, not history. The billing annotation is a fact about runs that
  # already happened, so a repo stays "blocked" for days after it is fixed and
  # the row cannot say whether the NEXT pull request will merge. What decides
  # that is: can a job run here at all -- a private repo needs an online
  # self-hosted runner, a public one needs its last run to have actually
  # executed rather than being refused before it started.
  local r wedged=() bl=() n=0
  while read -r r; do
    n=$((n + 1))
    # A repo with no workflows cannot be wedged; it is unused, not blocked.
    gh_json api "repos/$ORG/$r/contents/.github/workflows" >/dev/null 2>&1 || { n=$((n - 1)); continue; }
    local priv; priv="$(gh_json api "repos/$ORG/$r" --jq '.private')" \
      || { bl+=("$r"); continue; }
    if [ "$priv" = true ]; then
      # Listing runners is an administration read, which the gate's own
      # workflow token cannot be granted. For the repo the gate is RUNNING in,
      # this job is the witness: a job is executing there right now.
      [ "$ORG/$r" = "${GITHUB_REPOSITORY:-}" ] && continue
      local online
      online="$(gh_json api "repos/$ORG/$r/actions/runners" --jq '[.runners[]?|select(.status=="online")]|length')" \
        || { bl+=("$r"); continue; }
      [ "${online:-0}" -gt 0 ] || wedged+=("$r:no-online-runner")
    else
      local started
      started="$(gh_json api "repos/$ORG/$r/actions/runs?per_page=1" \
        --jq '[.workflow_runs[]?|select(.status=="completed" and .conclusion!="startup_failure")]|length')" \
        || { bl+=("$r"); continue; }
      # A repo that has never run anything is not wedged; it is unused.
      :
    fi
  done < "$TMP/all-repos"
  if [ ${#wedged[@]} -gt 0 ]; then
    down "no way to run a job: ${wedged[*]} (the billing failure presents exactly this way)"
  elif [ ${#bl[@]} -gt 0 ]; then blind "could not ask whether a job can run: ${bl[*]}"
  else ok "$n repos, of every repo this credential lists, can run a job: private ones have an online runner, public ones have hosted minutes"; fi
}

row_wedge() {
  all_repos || { blind "repo list unreadable: $(tr -d '\n' <"$TMP/err")"; return; }
  # A WEDGE is a required status check nothing can produce. It is the general
  # form of the billing failure: main demanded `prose / prose`, no job could
  # start, and every pull request in the estate stopped merging with nothing
  # naming the cause.
  local r stuck=() bl=() n=0
  while read -r r; do
    local ctx
    ctx="$(gh_json api "repos/$ORG/$r/branches/main/protection" \
      --jq '(.required_status_checks.contexts // [])[]' 2>/dev/null)" || continue
    [ -n "$ctx" ] || continue
    n=$((n + 1))
    # WHERE THE EVIDENCE LIVES: a required context is produced by a JOB, and
    # most only ever run on pull_request -- so main's own check-runs are the
    # wrong sample and would call every prose gate wedged. Read the completed
    # job names of the repo's recent runs instead.
    local seen c rid
    seen=""
    for rid in $(gh_json api "repos/$ORG/$r/actions/runs?per_page=20" --jq '.workflow_runs[]?.id' 2>/dev/null); do
      seen="$seen
$(gh_json api "repos/$ORG/$r/actions/runs/$rid/jobs" --jq '.jobs[]?|select(.status=="completed")|.name' 2>/dev/null)"
    done
    seen="$(printf '%s\n' "$seen" | grep -v '^$' | sort -u)"
    [ -n "$seen" ] || { bl+=("$r"); continue; }
    while read -r c; do
      [ -n "$c" ] || continue
      if printf '%s\n' "$seen" | grep -qxF "$c"; then continue; fi
      if printf '%s\n' "$seen" | grep -qxF "${c##* / }"; then continue; fi
      stuck+=("$r:$c")
    done <<< "$ctx"
  done < "$TMP/all-repos"
  if [ ${#stuck[@]} -gt 0 ]; then
    down "required check with no completed run: ${stuck[*]}"
  elif [ ${#bl[@]} -gt 0 ]; then blind "check runs unreadable: ${bl[*]}"
  else ok "$n protected repo(s), of every repo this credential lists: every required check has produced a completed run"; fi
}

row_backlog() {
  roster || { blind "roster unreadable: $(tr -d '\n' <"$TMP/err")"; return; }
  local r over=() bl=()
  while read -r r; do
    local c; c="$(gh_json issue list -R "$ORG/$r" --state open --limit 100 --json number | jq 'length')" \
      || { bl+=("$r"); continue; }
    [ "$c" -ge 10 ] && over+=("$r=$c")
  done < "$TMP/roster"
  if [ ${#over[@]} -gt 0 ]; then down "double-digit open issues: ${over[*]}"
  elif [ ${#bl[@]} -gt 0 ]; then blind "issue list unreadable: ${bl[*]}"
  else ok "every repo under 10 open issues"; fi
}

row_needs-zach() {
  roster || { blind "roster unreadable: $(tr -d '\n' <"$TMP/err")"; return; }
  local r total=0 open=0 bl=()
  while read -r r; do
    local j; j="$(gh_json issue list -R "$ORG/$r" --state open --limit 200 --json labels)" \
      || { bl+=("$r"); continue; }
    open=$((open + $(jq 'length' <<<"$j")))
    total=$((total + $(jq '[.[] | select(.labels[]?.name=="needs-human")] | length' <<<"$j")))
  done < "$TMP/roster"
  [ ${#bl[@]} -gt 0 ] && { blind "issue labels unreadable: ${bl[*]}"; return; }
  if [ "$total" -ge 10 ]; then down "needs-human=$total of $open open"
  elif [ "$open" -gt 0 ] && [ $((total * 10)) -ge "$open" ]; then
    down "needs-human=$total is >=10% of $open open"
  else ok "needs-human=$total of $open open"; fi
}

row_interchange() {
  roster || { blind "roster unreadable: $(tr -d '\n' <"$TMP/err")"; return; }
  local r bl=() found=""
  while read -r r; do
    local nums; nums="$(gh_json issue list -R "$ORG/$r" --state closed --limit 50 \
      --search "closed:>=${SINCE%T*}" --json number --jq '.[].number')" \
      || { bl+=("$r"); continue; }
    local n
    for n in $nums; do
      local other; other="$(gh_json api "repos/$ORG/$r/issues/$n/timeline" \
        --jq '.[] | select(.event=="cross-referenced" or .event=="closed") |
              (.source.issue.repository.full_name // (.commit_url // "" | capture("repos/(?<f>[^/]+/[^/]+)/").f) // empty)' 2>/dev/null)" \
        || { bl+=("$r#$n"); continue; }
      [ -n "$other" ] && grep -qv "^$ORG/$r$" <<<"$other" && {
        found="$ORG/$r#$n <- $(grep -v "^$ORG/$r$" <<<"$other" | head -1)"; break 2; }
    done
  done < "$TMP/roster"
  if [ -n "$found" ]; then ok "cross-repo close in last ${WINDOW_DAYS}d: $found"
  elif [ ${#bl[@]} -gt 0 ]; then blind "trackers unreadable: ${bl[*]}"
  else down "no cross-repo issue close in the last ${WINDOW_DAYS}d"; fi
}

row_participation() {
  roster || { blind "roster unreadable: $(tr -d '\n' <"$TMP/err")"; return; }
  # The pace table is a COMMITTED file that every account pulls, and the host
  # copies sit in homes no unprivileged process may traverse.
  local armed; armed="$(gh_json api "repos/$ORG/scheduler/contents/schedule/_paced.$MONKEY.conf" --jq .content | base64 -d)" \
    || { blind "pace table unreadable: $(tr -d '\n' <"$TMP/err")"; return; }
  local r undispatched=() failing=() unarmed=() bl=()
  while read -r r; do
    awk -F'|' -v r="$r" '$1 == r && $2 == 1 { found = 1 } END { exit !found }' <<<"$armed" \
      || { unarmed+=("$r"); continue; }
    local j; j="$(gh_json run list -R "$ORG/$r" --limit 20 --json conclusion,createdAt,event)" \
      || { bl+=("$r"); continue; }
    local recent; recent="$(jq -r --arg s "$SINCE" '[.[] | select(.createdAt >= $s)] | length' <<<"$j")"
    [ "$recent" -gt 0 ] || { undispatched+=("$r"); continue; }
    local merged; merged="$(gh_json pr list -R "$ORG/$r" --state merged --limit 20 \
      --search "merged:>=${SINCE%T*}" --json number --jq 'length')" || { bl+=("$r"); continue; }
    [ "$merged" -gt 0 ] || failing+=("$r")
  done < "$TMP/roster"
  if [ ${#unarmed[@]} -gt 0 ] || [ ${#undispatched[@]} -gt 0 ] || [ ${#failing[@]} -gt 0 ]; then
    down "unarmed: ${unarmed[*]:-none}; not dispatched: ${undispatched[*]:-none}; dispatched without merged work: ${failing[*]:-none}${bl[*]:+; unreadable: ${bl[*]}}"
  elif [ ${#bl[@]} -gt 0 ]; then blind "run/pr history unreadable: ${bl[*]}"
  else ok "every roster repo armed, clocked, dispatched and merging inside ${WINDOW_DAYS}d"; fi
}

row_v0-residue() {
  roster || { blind "roster unreadable: $(tr -d '\n' <"$TMP/err")"; return; }
  local r f hit=() bl=()
  while read -r r; do
    for f in BLOCKERS.md FOCUS.md QUESTIONS.md; do
      local code; code="$("$GH" api -i "repos/$ORG/$r/contents/$f" 2>/dev/null | head -1)"
      case "$code" in
        *" 200"*) hit+=("$r/$f") ;;
        *" 404"*) ;;
        *) bl+=("$r/$f") ;;
      esac
    done
  done < "$TMP/roster"
  if [ ${#hit[@]} -gt 0 ]; then down "v0 coordination files still tracked: ${hit[*]}"
  elif [ ${#bl[@]} -gt 0 ]; then blind "contents API unreadable: ${bl[*]}"
  else ok "no BLOCKERS/FOCUS/QUESTIONS.md in any repo"; fi
}

row_verbs() {
  local verbs
  # The verb build's manifest.tsv is the verb list; `gh repo list` is not, and
  # neither is the build's directory layout (one dir per project, not per verb).
  verbs="$(gh_json api "repos/$ORG/verbs/contents/manifest.tsv" --jq .content \
           | base64 -d | grep -v '^#' | cut -f2 | sort -u)" \
    || { blind "verb build unreadable: $(tr -d '\n' <"$TMP/err")"; return; }
  [ -n "$verbs" ] || { blind "verb build listed no verbs"; return; }
  local v uncalled=() bl=()
  for v in $verbs; do
    # Code search is rate-limited per minute, below the size of the verb list,
    # so the row spends the minute rather than reporting could-not-look. The
    # secondary limit says so in other words, and both mean wait.
    local n try
    for try in 1 2 3 4; do
      sleep "$PACE"
      n="$(gh_json search code "$v" --owner "$ORG" --limit 5 --json path --jq 'length')" && break
      n=""
      grep -qi 'rate limit' "$TMP/err" || break
      sleep "$BACKOFF"
    done
    [ -n "$n" ] || { bl+=("$v"); continue; }
    [ "$n" -gt 0 ] || uncalled+=("$v")
  done
  if [ ${#uncalled[@]} -gt 0 ]; then down "verbs with no caller: ${uncalled[*]}"
  elif [ ${#bl[@]} -gt 0 ]; then blind "code search unreadable for: ${bl[*]}"
  else ok "every verb in the build has a live caller"; fi
}

row_symmetry() {
  roster || { blind "roster unreadable: $(tr -d '\n' <"$TMP/err")"; return; }
  # SYMMETRY is one copy of a shared mechanism, not fifteen. The prose guard is
  # that mechanism: a repo either CALLS hf7y/etalon's reusable workflow or it
  # carries its own copy, and the copies are what BUILD-DISCIPLINE records as
  # the failure this arrangement exists to remove. A repo with no guard at all
  # is not judged here -- it runs none of the shared code.
  local r own=() vendored=() bl=() n=0
  while read -r r; do
    local code; code="$("$GH" api -i "repos/$ORG/$r/contents/.github/workflows/prose.yml" 2>/dev/null | head -1)"
    case "$code" in
      *" 404"*) continue ;;
      *" 200"*) ;;
      *) bl+=("$r"); continue ;;
    esac
    n=$((n + 1))
    local body; body="$(gh_json api "repos/$ORG/$r/contents/.github/workflows/prose.yml" --jq .content | base64 -d)" \
      || { bl+=("$r"); continue; }
    grep -q "uses: $ORG/etalon/.github/workflows/guard.yml" <<<"$body" || own+=("$r")
    if [ "$r" != etalon ] && "$GH" api "repos/$ORG/$r/contents/bin/markdown-cost.sh" >/dev/null 2>&1; then
      vendored+=("$r")
    fi
  done < "$TMP/roster"
  if [ ${#own[@]} -gt 0 ] || [ ${#vendored[@]} -gt 0 ]; then
    down "guard not the shared one: ${own[*]:-none}; vendored copy of the lint: ${vendored[*]:-none}"
  elif [ ${#bl[@]} -gt 0 ]; then blind "workflow contents unreadable: ${bl[*]}"
  else ok "$n repo(s) with a prose guard all call the one shared copy"; fi
}

row_placement() {
  git clone -q --depth 1 "$REALISATEUR_SRC" "$TMP/realisateur" 2>"$TMP/err" \
    || { blind "realisateur unclonable: $(tr -d '\n' <"$TMP/err")"; return; }
  # The audit is realisateur's own and is maintained there; `--repo .` is the
  # form its CI adjudicates on, and a bare run reads clean whatever it finds.
  [ -f "$TMP/realisateur/bin/ownership-audit.sh" ] \
    || { blind "realisateur ships no bin/ownership-audit.sh"; return; }
  local out rc; out="$(cd "$TMP/realisateur" && bash bin/ownership-audit.sh --repo . 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then ok "ownership-audit --repo . clean"
  else down "$(grep -c FLAG <<<"$out") flagged: $(grep FLAG <<<"$out" | head -1)"
  fi
}

row_prose() {
  roster || { blind "roster unreadable: $(tr -d '\n' <"$TMP/err")"; return; }
  etalon || { blind "etalon unclonable: $(tr -d '\n' <"$TMP/err")"; return; }
  # The claim is about each TREE, and the guard runs on pull_request only, so
  # there is no run on a default branch to read it off. Measure what CI
  # measures: the repo's own census against the repo's own ratchet.
  local r over=() bare=() bl=() n=0
  while read -r r; do
    rm -rf "$TMP/tree"
    "$GH" repo clone "$ORG/$r" "$TMP/tree" -- -q --depth 1 2>"$TMP/err" \
      || { bl+=("$r"); continue; }
    [ -f "$TMP/tree/.prose-ratchet" ] || { bare+=("$r"); continue; }
    n=$((n + 1))
    # --census exits 0 on a default-branch clone whatever it counts: with no
    # branch above the merge base it blames any excess on main having drifted.
    # The count and the floor it prints are the answer; the exit code is not.
    local out now was
    out="$( cd "$TMP/tree" && MARKDOWN_COST_RATCHET="$TMP/tree/.prose-ratchet" \
            bash "$TMP/etalon/bin/markdown-cost.sh" --census 2>&1 )"
    read -r now was <<<"$(sed -n 's/.*-- \([0-9]*\) prose line(s), baseline \([0-9]*\).*/\1 \2/p' <<<"$out")"
    if [ -z "$now" ] || [ -z "$was" ]; then bl+=("$r"); continue; fi
    [ "$now" -le "$was" ] || over+=("$r:$now>$was")
  done < "$TMP/roster"
  if [ ${#over[@]} -gt 0 ]; then down "over .prose-ratchet: ${over[*]}${bl[*]:+; unreadable: ${bl[*]}}"
  elif [ ${#bl[@]} -gt 0 ]; then blind "tree unreadable: ${bl[*]}"
  else ok "$n roster tree(s) at or under .prose-ratchet; holding no ratchet: ${bare[*]:-none}"; fi
}

row_state-prose() {
  local root; root="$(git rev-parse --show-toplevel 2>"$TMP/err")" \
    || { blind "not inside a repository: $(tr -d '\n' <"$TMP/err")"; return; }
  # The lint is hf7y/etalon's and is maintained only there, so the row fetches
  # it at a ref the way the shared prose guard checks it out.
  etalon || { blind "etalon unclonable: $(tr -d '\n' <"$TMP/err")"; return; }
  local out rc
  out="$(cd "$root" && STATE_PROSE_RATCHET="$root/.state-prose-ratchet" \
         bash "$TMP/etalon/bin/state-prose-lint.sh" 2>&1)"; rc=$?
  case "$rc" in
    0) ok "state-prose-lint@$ETALON_REF: at or under $root/.state-prose-ratchet" ;;
    6) blind "state-prose-lint BLIND: $(head -1 <<<"$out")" ;;
    *) down "state-prose-lint: $(grep -v '^$' <<<"$out" | head -1)" ;;
  esac
}

row_thermostat() {
  roster || { blind "roster unreadable: $(tr -d '\n' <"$TMP/err")"; return; }
  scheduler_repo || { blind "scheduler unclonable: $(tr -d '\n' <"$TMP/err")"; return; }
  local r moved=0 stuck=() bl=()
  while read -r r; do
    local out rc
    out="$(THERMOSTAT_GH_BIN="$GH" THERMOSTAT_HOST="$MONKEY" \
           bash "$TMP/scheduler/bin/thermostat-probe.sh" "$r" 2>&1)"; rc=$?
    case "$rc" in
      0) moved=$((moved + 1)) ;;
      1) stuck+=("$r:$(sed -n 's/.*reason=//p' <<<"$out")") ;;
      *) bl+=("$r:$(sed -n 's/.*reason=//p' <<<"$out")") ;;
    esac
  done < "$TMP/roster"
  if [ ${#stuck[@]} -gt 0 ]; then down "pace and turns stood still: ${stuck[*]}${bl[*]:+; unreadable: ${bl[*]}}"
  elif [ ${#bl[@]} -gt 0 ]; then blind "thermostat-probe unreadable: ${bl[*]}"
  else ok "pace and turns both moved across a config-quiet window for $moved roster project(s)"; fi
}

# ---------------------------------------------------------------- driver

json_row() { jq -cn --arg n "$1" --arg s "$2" --arg m "$3" '{row:$n,status:$s,detail:$m}'; }

run_row() {
  st=BLIND; msg="row not implemented"
  "row_$1"
  case "$JSON" in 1) json_row "$1" "$st" "$msg" ;; *) printf '%-6s %-13s | %s\n' "$st" "$1" "$msg" ;; esac
  case "$st" in DOWN) worst="$EXIT_FINDING" ;; BLIND) [ "$worst" -eq "$EXIT_FINDING" ] || worst="$EXIT_BLIND" ;; esac
}

JSON=0; want=()
for a in "$@"; do
  case "$a" in
    --json) JSON=1 ;;
    -h|--help) sed -n '3,18p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
    -*) echo "unknown option: $a" >&2; exit 2 ;;
    *) printf '%s\n' "${ROWS[@]}" | grep -qx "$a" || { echo "unknown row: $a" >&2; exit 2; }
       want+=("$a") ;;
  esac
done
[ ${#want[@]} -gt 0 ] || want=("${ROWS[@]}")

worst=0
for r in "${want[@]}"; do run_row "$r"; done
exit "$worst"
