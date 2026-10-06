#!/usr/bin/env bash
# Test harness for bin/migration-landed.sh. Every probe is redirected at a
# fixture gh/ssh, so no real repo, host or account is ever read.
#
# Exit: 0 all assertions pass / 1 any assertion failed.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0

assert_rc() {
  if [ "$rc" -eq "$2" ]; then printf 'ok:   %s (rc=%s)\n' "$1" "$rc"
  else printf 'MISS: %s -- expected rc=%s, got %s\n%s\n' "$1" "$2" "$rc" "$out"; fails=$((fails+1)); fi
}
assert_has() {
  if grep -qF -- "$2" <<<"$out"; then printf 'ok:   %s\n' "$1"
  else printf 'MISS: %s (no "%s" in output)\n%s\n' "$1" "$2" "$out"; fails=$((fails+1)); fi
}
assert_lacks() {
  if grep -qF -- "$2" <<<"$out"; then printf 'MISS: %s ("%s" present)\n%s\n' "$1" "$2" "$out"; fails=$((fails+1))
  else printf 'ok:   %s\n' "$1"; fi
}

# gh stub: $T/gh-mode selects the scenario, one repo in the roster.
cat > "$T/gh" <<'GH'
#!/usr/bin/env bash
mode="$(cat "$FIXTURE/gh-mode")"
printf '%s\n' "$*" >> "$FIXTURE/gh-args"
[ "$mode" = dead ] && { echo "gh: fixture failure" >&2; exit 1; }
case "$1 $2" in
  "repo list") echo '[{"name":"alpha"},{"name":"songbook"}]' ;;
  "issue list") if [ "$mode" = backlog-over ]; then
                  jq -cn '[range(12) | {number:., labels:[]}]'
                else echo '[]'; fi ;;
  "api repos/hf7y/"*"/contents/.github/workflows") echo '[{"name":"prose.yml"}]' ;;
  "api repos/hf7y/alpha"|"api repos/hf7y/beta"|"api repos/hf7y/songbook") echo 'true' ;;
  "api repos/hf7y/"*"/actions/runners")
      if [ "$mode" = no-runner ]; then echo 0; else echo 1; fi ;;
  "api repos/hf7y/"*"/branches/main/protection")
      echo 'prose / prose' ;;
  "api repos/hf7y/"*"/actions/runs?per_page=20") echo 77 ;;
  "api -i") case "$3" in
        *contents/.github/workflows/prose.yml)
            [ "$mode" = no-guard-file ] && { echo "HTTP/2.0 404 Not Found"; exit 0; }
            echo "HTTP/2.0 200 OK" ;;
        *) echo "HTTP/2.0 404 Not Found" ;;
      esac ;;
  "api repos/hf7y/"*"/contents/.github/workflows/prose.yml")
      if [ "$mode" = own-guard ]; then body='uses: ./.github/workflows/local-guard.yml'
      else body='uses: hf7y/etalon/.github/workflows/guard.yml@main'; fi
      jq -rn --arg b "$body" '$b|@base64' ;;
  "api repos/hf7y/"*"/contents/bin/markdown-cost.sh")
      [ "$mode" = vendored ] || exit 1
      echo '{}' ;;
  "api repos/hf7y/scheduler/contents/schedule/_paced.fixturehost.conf")
      jq -rn '"# a comment\nalpha|1|1|run alpha\nbeta|0|1|run beta"|@base64' ;;
  "search code")
      # The first query of a run rate-limits; the retry must survive it.
      if [ "$mode" = rate-limited ] && [ ! -e "$FIXTURE/searched" ]; then
        touch "$FIXTURE/searched"; echo "HTTP 403: API rate limit exceeded for user ID 1" >&2; exit 1
      fi
      echo 1 ;;
  "api repos/hf7y/verbs/contents/manifest.tsv") jq -rn '"p\tdose"|@base64' ;;
  "api repos/hf7y/"*"/actions/runs/77/jobs")
      if [ "$mode" = wedged ]; then echo 'something-else'; else echo 'prose / prose'; fi ;;
  *) echo "gh: fixture failure" >&2; exit 1 ;;
esac
GH
chmod +x "$T/gh"

cat > "$T/ssh-dead" <<'S'
#!/usr/bin/env bash
echo "ssh: connect to host monkey port 22: No route to host" >&2
exit 255
S
chmod +x "$T/ssh-dead"

run() {
  out="$(FIXTURE="$T" MIGRATION_LANDED_GH="$T/gh" MIGRATION_LANDED_SSH="$T/ssh-dead" \
         MIGRATION_LANDED_BACKOFF=0 MIGRATION_LANDED_PACE=0 MIGRATION_LANDED_ETALON="$T/no-etalon" \
         MIGRATION_LANDED_REALISATEUR="$T/no-realisateur" MIGRATION_LANDED_SCHEDULER="$T/no-scheduler" \
         MIGRATION_LANDED_MONKEY=fixturehost PATH="/usr/bin:/bin" \
         bash ./migration-landed.sh "$@" 2>&1)"
  rc=$?
}

printf '== fixture: %s\n\n' "$T"

# ------------------------------------------------ 1. BLIND is never OK
echo ok > "$T/gh-mode"
run thermostat
assert_rc "a BLIND row exits 6, not 0" 6
assert_has "thermostat reports BLIND with a reason" "BLIND  thermostat"
assert_has "and it names the harness it could not fetch" "scheduler unclonable"
assert_lacks "BLIND is not folded into OK" "OK "

# ------------------------------------------- 2. could-not-look != clean
echo dead > "$T/gh-mode"
run dispatch
assert_rc "unreadable roster is BLIND (6), not OK" 6
assert_has "dispatch says why it could not look" "roster unreadable"

# ---------------------------------------------- 3. a DOWN row exits 1
echo backlog-over > "$T/gh-mode"
run backlog
assert_rc "a DOWN row exits 1" 1
assert_has "backlog names the offender" "alpha=12"

# ----------------------------------- 4. DOWN outranks BLIND in one run
run backlog thermostat
assert_rc "DOWN beats BLIND for the exit code" 1
assert_has "the BLIND row is still printed" "BLIND  thermostat"

# -------------------------------------- 6. --json: one object per row
echo dead > "$T/gh-mode"
run --json
rows="$(grep -c "" <<<"$out")"
n_expected="$(grep -cE '^row_[a-z0-9-]+\(\)' ./migration-landed.sh)"
if [ "$rows" -eq "$n_expected" ]; then printf 'ok:   --json emits one line per row (%s)\n' "$rows"
else printf 'MISS: --json emitted %s lines for %s rows\n' "$rows" "$n_expected"; fails=$((fails+1)); fi
if jq -e '.row and .status and .detail' <<<"$out" >/dev/null; then
  printf 'ok:   every --json line is an object with row/status/detail\n'
else printf 'MISS: --json line missing a field\n%s\n' "$out"; fails=$((fails+1)); fi
assert_lacks "no --json row claims OK when nothing could be read" '"status":"OK"'

# ------------------- 6b. CI rows measure capability, not run history
echo ok > "$T/gh-mode"
run ci-free
assert_rc "a private repo with an online runner can run a job" 0
assert_has "and it says so in terms of capability" "can run a job"

echo no-runner > "$T/gh-mode"
run ci-free
assert_rc "a private repo with no online runner is DOWN" 1
assert_has "and the row names the repo and the reason" "alpha:no-online-runner"

echo ok > "$T/gh-mode"
run wedge
assert_rc "a required check that has produced a run is not a wedge" 0

echo wedged > "$T/gh-mode"
run wedge
assert_rc "a required check nothing produces is DOWN" 1
assert_has "and the wedge names repo and context" "alpha:prose / prose"

echo ok > "$T/gh-mode"
run state-prose
assert_rc "an unfetchable lint is BLIND (6), not a pass" 6
assert_has "and the row says the lint is what it could not get" "etalon unclonable"

echo ok > "$T/gh-mode"
run participation
assert_lacks "an enabled pace row is not read as unarmed" "unarmed: alpha"

# --------------------------- 8. symmetry is implemented, not delegated away
echo ok > "$T/gh-mode"
run symmetry
assert_rc "a repo calling the shared guard is symmetric" 0
assert_has "and the row says what it counted" "call the one shared copy"

echo own-guard > "$T/gh-mode"
run symmetry
assert_rc "a repo running its own guard is DOWN" 1
assert_has "and the row names it" "guard not the shared one: alpha"

echo vendored > "$T/gh-mode"
run symmetry
assert_rc "a vendored copy of the shared lint is DOWN" 1
assert_has "and the row names it" "vendored copy of the lint: alpha"

echo no-guard-file > "$T/gh-mode"
run symmetry
assert_rc "a repo with no guard at all is not judged" 0

# ------------- 9. prose measures the TREE, with the lint CI measures with
echo ok > "$T/gh-mode"
run prose
assert_rc "no census tool means BLIND, not a pass" 6
assert_has "and prose names the lint it could not fetch" "etalon unclonable"

run placement
assert_rc "no audit means BLIND, not a pass" 6
assert_has "and placement names what it could not fetch" "realisateur unclonable"

# ------------- 10. the code-search rate limit is a wait, not a blindness
echo rate-limited > "$T/gh-mode"; rm -f "$T/searched"
run verbs
assert_rc "verbs answers through a rate limit" 0
assert_lacks "and does not report could-not-look" "code search unreadable"

# ------------ 11. the roster is what self-dev runs, not what the account owns
echo ok > "$T/gh-mode"
run participation
assert_has "a parked row in the registry is unarmed" "unarmed: beta"
assert_lacks "a repo no registry names is not judged at all" "songbook"
assert_has "a DOWN row still names what it could not read" "unreadable: alpha"

# ------------------------------------------------- 7. usage is not a pass
run --nonsense
assert_rc "an unknown option exits 2" 2
run nosuchrow
assert_rc "an unknown row exits 2" 2

printf '\n%s\n' "$([ "$fails" -eq 0 ] && echo 'ALL PASS' || echo "$fails FAILED")"
[ "$fails" -eq 0 ]
