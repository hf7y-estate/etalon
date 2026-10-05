# The estate as a control system, and the smallest thermostat that closes the loop

Research pass, 2026-10-05. Closes hf7y-estate/etalon#94. Every claim below
carries the command that produced it or is marked **UNVERIFIED**/**BLIND**.
This runs in a container with no host access; anything beyond
hf7y-estate/senechal#1083's 2026-10-05T06:42:22Z snapshot is BLIND by
construction, and is called out as such.

## Five-line verdict

1. The estate has sensors (`usage-gate.sh`'s 5h/7d quota reading,
   `thermostat-veto.sh`, `etiquette.sh`, `will-it-run.sh`) but the
   dispatcher (`nightly.sh`) reads only one of them automatically
   (`etiquette.sh`, wired this week). The others are read by a person
   pasting a command into an issue, or not read at all — a thermostat with
   a working thermometer nobody has wired to the furnace.
2. Of the four stages Zach specified for the thermostat — **veto, score,
   calibration, allocation** (hf7y-estate/etalon#79, item 3) — only veto is
   built (hf7y-estate/etalon#82 → PR hf7y-estate/etalon#85, merged). "Spend
   follows reviewed score" is not a working mechanism yet; it is a plan with
   one of its four legs standing.
3. This week's one real feedback measurement — 21 containers burn the weekly
   quota no faster than 4 (hf7y-estate/realisateur#1476) — says the lever is
   **hours running**, not parallelism. `nightly.sh` still treats concurrency
   as free and sets its budget from the length of a hand-maintained list,
   not from any measured cost.
4. At least two loops are open with no limit at all today: a forced pass with
   no attempt/spend brake (hf7y-estate/realisateur#1382, OPEN, filed
   2026-10-01, still unbuilt), and a merge backlog with no "stuck N nights"
   escalation (measured below: 52 of 152 recorded merge outcomes are
   `HELD`). Both can spend without bound in their current form.
5. The single host every pass depends on has no remote power-on, and the
   estate noticed an 11-hour outage only because a person happened to look
   (hf7y-estate/realisateur#1441, OPEN). That is a bigger near-term threat to
   throughput than the thermostat's precision — a control loop running on a
   plant that can silently go dark is not well-served by a smarter
   controller.

## The argument

### What is the controlled variable

The estate's own documents name two, and admit a third is wanted and
doesn't exist:

- **A. Weekly quota used.** Zach, 2026-10-05, on realisateur#1476: *"We're
  not on track to burn this quota."* The explicit target is "spend what the
  week allows," unquantified beyond that sentence.
- **B. Share of merged passes whose work survives review.** Zach, 2026-10-01
  (quoted on hf7y-estate/etalon#79's comment and hf7y-estate/realisateur#1394):
  *"Issues closed is not the best proxy because it results in weird issue
  spam... We need a combination of Zach QC and agent peer-review QC to make
  this thermostat more meaningful."* This is **B**'s setpoint in words, not
  a number: work that a reviewer and Zach would call good, not junk.
- A third informal variable, **turn/cost efficiency per pass**, is measured
  in logs (`grep '^=== result'` → turns 26–95, cost \$0.50–\$3.49 over three
  nights, per etalon#79's own comment) but is not wired to anything; it is
  a reading with no setpoint and no actuator, i.e. not actually a controlled
  variable yet, just a number someone can grep.

### What senses each variable, today

- **A** is sensed by `scheduler/bin/usage-gate.sh`
  (`gh api repos/hf7y-estate/scheduler/contents/bin/usage-gate.sh`): it reads
  Anthropic's account-wide unified rate-limit headers
  (`anthropic-ratelimit-unified-{5h,7d}-utilization`), computes an
  even-burn line from window-start to the window's reset, and exits
  0 (RUN) / 1 (HOLD) / 2 (ERROR→treat as HOLD). It is a real, working
  sensor. hf7y-estate/realisateur#1476 shows it being read **by hand**:
  *"`bash scheduler/bin/usage-gate.sh`: 7d util 0.320 at 05:37Z, 0.330 at
  06:39Z."* Nothing in `agent/nightly.sh`
  (`gh api repos/hf7y-estate/realisateur/contents/agent/nightly.sh`) calls
  it. `nightly.sh`'s own comment is explicit that this was a deliberate
  trade, made at a *different* level than the one #1476 is asking about:
  *"usage-gate.sh -> nothing. A 429 fails a repo's pass and the loop moves
  on. A coordinator traded for a retry, deliberately."* That retired a
  **per-container, reactive** use of the sensor (block before a call that
  would 429). hf7y-estate/realisateur#1476 is asking for a **nightly-
  aggregate, proactive** use of the same sensor (set `NIGHT_PASSES` from
  measured cost against the window) — a different control point that was
  never wired in the first place, not the one that was deliberately removed.
- **B** has no sensor. Stage 2 of the thermostat ("a review pass... grades a
  sample of merged work against the issue text only") is explicitly listed
  as deferred on hf7y-estate/etalon#82: *"Score, calibration and allocation
  each depend on infrastructure that doesn't exist yet... and are not
  scoped here."* `thermostat-veto.sh` (built) can only refuse a score; there
  is nothing yet that grants one. So **B cannot be read at all today** —
  not "sensed badly," simply absent.

### What actuates each variable, today

- **A**'s actuator is `nightly.sh`'s `night` budget
  (`NIGHT_PASSES`, default = number of repos in `agent/repos`, currently 12
  per hf7y-estate/senechal#1083's snapshot: *"night budget of 12 pass(es)
  spent"*) and the number of concurrent `--send` chains a person starts by
  hand. Both are set by a human typing a number, not by anything measured.
- **B** has no actuator either, for the same reason it has no sensor: there
  is nothing yet that "allocates by reviewed score," because there is no
  score. `realisateur#1395` (merged) added the `PASSES` knob *in
  anticipation* of this — its own body says plainly, *"Nothing here decides
  the number: 1 stays the cron default, and the thermostat is what should
  set it."* A knob exists; nothing turns it.

### Setpoint, and who sets it

For **A**: no number is written down anywhere as a target utilization.
Zach's sentences ("not on track to burn this quota") are the only setpoint,
held in his head, re-derived by a person each time someone measures
`usage-gate.sh` by hand. For **B**: same — "good, not junk," ratified by
Zach's own spot-check comments, which is the right design (Ashby again:
a human judgment that resists Goodharting is a legitimate setpoint source)
but is not wired to anything that reads it systematically yet. The one place
a setpoint genuinely is machine-readable today is the **label grammar**
(`bin/lib/labels.tsv`, read by `etiquette.sh`): `DECISION:` bodies carry a
literal `DEFAULT-AFTER <n>d: <action>` line that *is* a setpoint a machine
executes without asking a human twice. That mechanism is the estate's best
working example of "a setpoint a human set once, that a loop then holds
without supervision" — and it was only wired into the nightly dispatcher
this week (PR hf7y-estate/realisateur#1470, merged 2026-10-05: *"`etiquette
--apply` on each repo before counting its queue"*). Before that PR, per its
own body: *"nothing ever executed that line... So silence did not take the
default; it parked the issue for good."* That is a loop that was open for
as long as the grammar existed and got closed days before this pass ran —
worth naming as an existence proof that the estate *can* close a loop, not
only diagnose one.

### Where the loops are open

1. **Quota sensor → nightly budget (A).** Open by omission, as above.
   `NIGHT_PASSES` does not read `usage-gate.sh`.
2. **Review → allocation (B).** Not open — *absent*. There is no score to
   feed `PASSES`, so "allocation follows reviewed score" (the design's own
   words, hf7y-estate/realisateur#1394) describes nothing that runs.
3. **Forced-pass attempts → a stop condition.** hf7y-estate/realisateur#1382
   is open, filed 2026-10-01, and its own body states the defect it's meant
   to fix is still live: *"nothing stops a pass that keeps failing."* A
   repo+issue sent with `--send` can be resent indefinitely with no
   recorded attempt count and no spend ceiling.
4. **Merge backlog → escalation.** `merge-carry.sh`
   (`gh api repos/hf7y-estate/realisateur/contents/agent/merge-carry.sh`)
   merges exactly the PR numbers the previous pass on that repo opened, and
   on anything not cleanly mergeable (`HELD`) or not yet merge-computed, it
   re-queues the same number for the *next* pass, forever — there is no
   counter and no "this PR has been stuck N nights" finding. Measured,
   hf7y-estate/senechal#1083's snapshot, "merge-carry outcomes, all logs":

   | Outcome | Count |
   |---|---|
   | MERGED | 95 |
   | HELD | 52 |
   | DONE | 4 |
   | FAILED | 1 |

   One in three recorded outcomes across the estate's history is `HELD` —
   open, mergeable-state unresolved or conflicting, carried forward with no
   limit. `merge-carry.sh`'s own comment records a `HELD`-adjacent failure
   mode already realized once: *"realisateur#1440 landed on a failed suite
   and turned main red"* — i.e. a merge went through on a state the script's
   simple `OPEN false MERGEABLE` match didn't exclude at the time; the
   script now also classifies a `statusCheckRollup` failure as `RED` and
   routes it to the `HELD` branch rather than merging it (confirmed by
   reading the script: the exact-match case `"OPEN false MERGEABLE"` cannot
   match a string with `RED` appended, so it falls through to the `OPEN*`
   branch and is held). The fix for *that* specific failure mode landed; the
   backlog-with-no-escalation failure mode it's a special case of did not.
5. **Host availability → wake path.** hf7y-estate/realisateur#1441 (OPEN,
   filed 2026-10-04): dexter — the only host any pass or the nightly
   dispatcher runs on — went dark at a measured `2026-10-04T11:09:13Z` and
   was still dark at `22:38Z`, over eleven hours, noticed because a person
   happened to check `tailscale status`. No wake-on-LAN is configured
   (`git grep -i -E 'wake-?on-?lan|wakeonlan|etherwake'` in that repo: 0
   hits, per the issue). This is upstream of every loop above: a thermostat
   on a furnace that can silently lose power is not improved by better
   setpoint logic.

### Where the gain is wrong

hf7y-estate/realisateur#1476's second comment is the clean case: width
(concurrent containers) was treated as a free actuator for throughput, and
measured, it is not. 3–4 containers and 21 containers burned quota at the
same rate (**+0.02 pp/min** in both windows, `bash
scheduler/bin/usage-gate.sh`), but the 21-container window finished *fewer*
passes in the hour (5 vs 7) with every container measured
(`docker stats --no-stream`) under 1.1% CPU and 118–205 MiB — the containers
were not compute-bound, they were waiting on something outside the host
(server-side throttling is the stated hypothesis; the comment is explicit
that *what* they waited on is **UNVERIFIED**, since `grep -c -i
'429\|rate.limit'` on the logs was 0 but the log is a filtered tool trace).
The actuator's gain did not merely plateau, it inverted: more control
effort produced less output. `nightly.sh` has no model of this — it has no
width control at all; a `--send` chain's concurrency is whatever a person
types. Ashby's point directly: the controller's variety here is a single
scalar (how many containers someone starts), and the disturbance (server-
side pacing behavior under load) has structure that scalar cannot represent,
so naive increases in that scalar can move the system the wrong way.

### Which existing guards are sensors wired to nothing

- `usage-gate.sh` — a real, working sensor (5h and 7d account-wide
  utilization against Anthropic's own rate-limit headers), consumed only by
  a person pasting its output into an issue body. Not called by
  `nightly.sh`, `run-agent.sh`, or anything on a schedule, as far as this
  container can read (`gh api .../agent/nightly.sh`, `.../agent/run-agent.sh`
  — neither mentions `usage-gate.sh` or `usage_gate`).
- The pass logs' own `=== result ... turns=... cost=$...` lines — read by a
  human for etalon#79's one-off measurement, and read by `thermostat-veto.sh`
  only as a labelled-low-confidence fallback. The script's own header is
  blunt about this: *"the pass's own `/srv/agent/*.log` format cannot be
  read from this container (needs-host) and is unconfirmed beyond the one
  data point... `--log` is therefore a best-effort SECOND source... never
  authoritative over CI."* A sensor that the primary consumer (a container)
  structurally cannot read is a sensor wired to nothing from inside the
  loop that is supposed to use it.
- GitHub's own branch-protection check: `merge-carry.sh`'s comment records
  *"0 required status checks on all 32 repos"* measured 2026-09-26. The
  platform's native merge-gate sensor is simply not provisioned anywhere in
  the org; `merge-carry.sh`'s hand-rolled `statusCheckRollup` read is a
  workaround standing in for a guard that was never turned on at the source.
- `will-it-run.sh` and `thermostat-veto.sh` themselves: both are built,
  tested, and merged, but neither is called by any of `nightly.sh`,
  `run-agent.sh`, or a scheduled workflow in this repo's own
  `.github/workflows/tests.yml` (`cat .github/workflows/tests.yml` — it runs
  this repo's test *suite*, not these tools against the live estate). They
  are commands a person or a pass can run by hand; nothing calls them on a
  clock. `will-it-run.sh` exists precisely because *"ensuring an issue will
  eventually get worked should be a mechanical thing any agent can check"*
  (Zach, quoted on etalon#79) — it mechanized the check, but nothing yet
  runs it proactively over the queue to surface a stranded issue before a
  human notices, which is the failure mode (space-canon#4/#11) it was built
  to answer.

## The smallest thermostat that closes the loop on two variables

**Variable 1 — weekly quota used.**

- Sensor: `usage-gate.sh` (exists).
- Actuator: `NIGHT_PASSES` / `PASSES` (exists).
- The missing link, smallest form: `nightly.sh` calls `usage-gate.sh` once
  at the top of its run and logs the 7d utilization next to the existing
  budget line (one line of real plumbing, zero new infrastructure). The
  *policy* that number should drive is **not** "run more containers" —
  #1476's own measurement rules that out — it is "run more **hours**": the
  smallest correct actuation is scheduling additional dispatch windows
  across the day at the width already proven not to degrade (hf7y-estate/
  realisateur#1476's own amended done-when: "find the width past which a
  pass slows... hold the estate at it, and run for as many hours... the
  window `usage-gate.sh` reports can pay for"). A width search is a
  bounded, one-pass measurement; wiring the sensor's reading into a log
  line is a few lines; neither requires the score/calibration machinery
  below.

**Variable 2 — share of passes whose work survives review.**

- Sensor: does not exist; this is the real gap. Minimal version: a command
  parallel to `thermostat-veto.sh` — call it `thermostat-score.sh` — that
  takes a repo+PR *already past veto* and grades it against its own
  closing issue's stated done-when/acceptance text (the same field
  `thermostat-veto.sh` already reads via `closingIssuesReferences`), on a
  small rubric (did it do what the issue asked; was it necessary; do its
  tests test anything; net lines added or deleted — the exact four
  questions hf7y-estate/senechal#1083 was asked to apply by hand on 25
  samples). It must have **no build task of its own**, per Zach's
  design (hf7y-estate/etalon#79's comment) — the stated reason, *"a pass
  reviewing work it will build on has a reason to pass it,"* is a direct,
  named Goodhart/incentive-alignment concern and should not be relaxed for
  convenience.
- Calibration: Zach's own GitHub comment on the *same* sampled PR, picked
  up the same way `etiquette.sh` already picks up a `DECISION:` ruling —
  reusing `bin/lib/body-grammar.sh`'s existing convention
  (`gh api repos/hf7y-estate/realisateur/contents/bin/etiquette.sh` shows
  this file already being sourced) rather than inventing a second grammar
  for comment ingestion.
- Allocation: the produced per-repo score feeds `realisateur`'s existing
  `PASSES`/`NIGHT_PASSES` knobs (`realisateur#1395`, merged; the brake it
  should be bounded by is `realisateur#1382`, open).
- **What the score is computed from:** the issue's own stated done-when
  text, plus the diff, never issue-closed counts or lines-changed counts in
  isolation — this is already the estate's explicit, named defense against
  Goodhart ("issues closed is not the best proxy... results in weird issue
  spam"), and `thermostat-veto.sh`'s existing "no done-when stated → veto"
  check is the right precedent to extend, not replace.
- **How it avoids becoming the target:** three guards already specified in
  the design and worth re-stating because they are the actual anti-Goodhart
  mechanism, not an afterthought: (a) veto is **subtractive only** — it can
  refuse a score, never grant or raise one, so gaming the veto checks at
  best gets you to "ungated," never to "high score"; (b) the review pass
  has no build incentive, cutting the most obvious collusion path; (c)
  Zach's spot-check is continuous calibration against the *same sampled*
  work, not a separate audit of the audit, so rubric drift gets corrected
  from ground truth repeatedly rather than once. The one place this can
  still leak, and isn't yet addressed anywhere: if the sample a pass can
  predict (e.g., always "the most recent N merged PRs") is small and
  stable, later passes converge on gaming exactly that predictable subset.
  Sampling should be unannounced and not simply "most recent."

## Ranked list of concrete changes

Each sized to one pass, one issue.

1. **Wire `nightly.sh`'s budget to `usage-gate.sh`.** Log the 7d utilization
   next to the existing budget line; closes the specific gap
   hf7y-estate/realisateur#1476 measured. Smallest possible first step
   toward variable A's loop — logging before acting lets the next issue
   decide the control law with real numbers in hand.
2. **Measure the concurrency width past which a pass slows**
   (hf7y-estate/realisateur#1476's own amended done-when) — a bounded
   measurement, not a redesign; its output is a number the previous item's
   control law needs.
3. **Build `thermostat-score.sh`** (stage 2 of 4, hf7y-estate/etalon#79
   item 3): grade one already-vetoed merged PR against its issue's
   done-when text, no build task attached. This is the single highest-
   leverage gap in the whole design — nothing past it (calibration,
   allocation) can exist before it does.
4. **Build calibration ingestion**: read a `GOOD`/`JUNK`/`WRONG`-shaped
   GitHub comment from Zach on a scored PR, reusing
   `bin/lib/body-grammar.sh`'s existing comment-reading convention from
   `etiquette.sh`, and record where it disagrees with the automated score.
5. **Wire the produced score into `realisateur`'s `PASSES`/`NIGHT_PASSES`**
   (stage 4; the knob already exists, per hf7y-estate/realisateur#1395).
6. **Build the forced-pass attempt/spend brake**
   (hf7y-estate/realisateur#1382, already filed, still open) — without it,
   a chain sent at one stuck issue has no stop condition at all, independent
   of anything the thermostat does.
7. **Escalate a chronically-`HELD` PR** out of `merge-carry.sh`'s silent
   carry-forward — a count of "nights held" past some N should produce a
   finding (comment/label), the same pattern realisateur#1382 proposes for
   a stuck forced issue, applied to the merge side of the loop instead of
   the dispatch side.
8. **A wake path for dexter** (hf7y-estate/realisateur#1441, already filed,
   needs-host — a human must change a BIOS setting once). Not a thermostat
   change at all, but the plant everything above assumes is live; ranked
   here because an eleven-hour silent outage is a bigger loss of throughput
   than any inefficiency the thermostat could ever correct.

## What was BLIND

- Any host state beyond hf7y-estate/senechal#1083's
  `2026-10-05T06:42:22Z` snapshot (container list, crontab, `/srv` layout,
  night-by-night dispatch log) — this container cannot reach dexter or
  mandark. Everything above sourced from that snapshot is marked by its
  citation of that issue.
- Whether `usage-gate.sh`'s 7d utilization has moved since
  hf7y-estate/realisateur#1476's last reading (`06:39Z`, 0.330) — no live
  read is possible from here.
- Whether dexter is currently powered (hf7y-estate/realisateur#1441 is still
  open as of this pass, which is the only signal available).
- The exact server-side cause of the width-vs-throughput inversion in
  hf7y-estate/realisateur#1476's second comment — that issue itself marks
  it UNVERIFIED (`grep -c -i '429\|rate.limit'` was 0, but the log is
  described as a filtered tool trace, so absence of the string is not
  evidence of absence of throttling).
