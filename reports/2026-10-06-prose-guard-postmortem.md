# The prose guard was the wrong shape: why it failed, what replaces it

Research pass, 2026-10-06. Closes hf7y-estate/etalon#92. Every claim below
carries the `gh`/`git` command that produced it, or is marked **UNVERIFIED**
or **BLIND**. This runs in a container with no host access and a token that
cannot read Actions run logs on any repo (`gh api
repos/<owner>/<repo>/actions/runs` returns `403 Resource not accessible by
integration` on every repo tried, public or private) -- so the evidence below
is built from the Checks API (`.../commits/<sha>/check-suites`, which does
work) and from PR bodies other sessions already wrote, not from raw logs.

## Five-line verdict

1. The guard's dominant failure mode was never a wrong verdict -- it was no
   verdict at all. At least 10 of the 11 repos that still carry `prose.yml`
   call `uses: hf7y/etalon/...@main`, a reference that stopped resolving when
   the org renamed `hf7y` -> `hf7y-estate` on 2026-09-25. Their check suites
   complete `conclusion: failure` with `latest_check_runs_count: 0` -- a job
   that never started -- confirmed directly against 9 of them and
   independently diagnosed and fixed in hf7y-estate/groc-mangr#388.
2. Where the guard *did* get a runner, the runner didn't exist either:
   hf7y-estate/senechal pinned it to `self-hosted`, and
   `gh api repos/hf7y-estate/senechal/actions/runners` reads `total_count: 0`.
   Two PRs (#1012, #1014) sat 12 days and were merged anyway; a third (#999)
   was closed instead of merged.
3. Where the guard ran for real and found real debt, it was ignored, not
   paid: hf7y-estate/wtul's own retirement PR (#445) quotes `state-prose-lint`
   reading red on its last five merged PRs (#438, #439, #440, #442, #444),
   and stopped none of them.
4. None of the three is a missing-enforcement bug to fix -- `prose` /
   `state_prose` was never in any sampled repo's actual GitHub
   `required_status_checks` (hf7y-estate/crt: none configured;
   hf7y-estate/realisateur: only `suites`; hf7y-estate/etalon: none), and all
   11 repos still carrying the guard are **private**, where GitHub branch
   protection is a paid feature this org doesn't have
   (`403 Upgrade to GitHub Pro`). "Required" was a word in a workflow file's
   own `name:`, never a platform guarantee, everywhere this was checked.
5. Under all three failure modes sits one design defect: the grader prices
   the whole tree, not the diff. wtul's own quoted reading --
   `state-prose-lint -- 40 state-describing line(s) of 1615 considered,
   baseline 36` -- is a tree count. A guard built that way punishes the PR in
   front of it for debt the PR did not add, which is #92's own framing of
   defect 1, independently confirmed here.

## The table: every repo that ever ran `prose.yml`, and what happened

`git log`/`gh` run against `hf7y-estate`'s 31 repos,
2026-10-06 (etalon excluded -- it is the guard's home, not a caller):

```
for r in <31 repo names>; do
  gh api repos/hf7y-estate/$r/contents/.github/workflows/prose.yml   # HAS today?
  gh api "repos/hf7y-estate/$r/commits?path=.github/workflows/prose.yml&per_page=100"  # ever existed?
done
```

| outcome | count | repos |
|---|---:|---|
| Never carried the guard | 7 | space-canon, cinema-sanctuary, dog, verbs, inv-redirects, vkv23, vibe-kiosk |
| Empty repo, N/A | 1 | selfdev-permission-witness-scratch |
| Carried it, removed outright (Zach's 2026-10-01 retire ruling, #77) | 11 | senechal, wtul, musc-2300, crt, chezz, realisateur, scheduler, abc, front-door, gardien, american-cycle |
| Still carries it, startup failure -- stale org reference, 0 check runs | 10 | secretaire, bibliothecaire, nine-speakers, abletim, vim-arcade, ecosim, apms-2173, baudin, dcp-gate-site, groc-mangr |
| Still carries it, last PR predates the 2026-09-25 rename -- unconfirmed either way | 1 | sequestria (**UNVERIFIED** beyond this) |

Per-repo evidence for the "startup failure" row, each independently queried
against that repo's own most recent PR:

```
$ gh pr list --repo hf7y-estate/<repo> --state all --limit 1 --json number,headRefOid
$ gh api "repos/hf7y-estate/<repo>/commits/<sha>/check-suites?per_page=100" \
    -q '.check_suites[] | select(.app.slug=="github-actions") | "\(.conclusion)/\(.latest_check_runs_count)"'
```

| repo | PR | sha | github-actions suites (conclusion/runs) |
|---|---|---|---|
| secretaire | #73 | 42d94c5cdb | `null/1`, `failure/0` |
| bibliothecaire | #156 | da62ac4666 | `failure/0` |
| nine-speakers | #90 | fb5f8ebbc9 | `failure/0` |
| abletim | #100 | 30de4878ce | `failure/0` |
| vim-arcade | #327 | d410d9c172 | `cancelled/1`, `failure/0` |
| ecosim | #126 | e1baf84dbd | `failure/0` |
| apms-2173 | #175 | 44d6873438 | `failure/0` |
| baudin | #87 | f5a0db2b55 | `failure/0` |
| dcp-gate-site | #121 | 2f8f64e37c | `cancelled/1`, `cancelled/1`, `failure/0` |
| groc-mangr | not from this probe -- its own PR #388 body, below | | |
| sequestria | #48 | a401edd781 | `success/2`, `success/2` -- PR merged 2026-09-06, **before** the 2026-09-25 rename |

`failure` with `0` check runs is the signature of a job that never got
created -- the sibling `success`/`cancelled` suites on the same commit
produce real check runs, this one does not. hf7y-estate/groc-mangr#388 ran
the same diagnosis independently and reached the same conclusion, with the
actual root cause named (quoting that PR's body):

> `prose.yml`'s `uses:` referenced `hf7y/etalon/...@main` -- `hf7y` was this
> org's login before it renamed to `hf7y-estate`. Repo-rename redirects
> cover `git clone` and the REST API, but not a reusable workflow's `uses:`
> resolution... A check suite that completes `failure` with zero check runs
> is a job that never got created, not one that ran and failed.

groc-mangr's PR #388 (still open as of this writing) chose to **fix** the
stale reference rather than retire the guard -- a live disagreement with
#77's retire ruling that this report surfaces but does not resolve.

### The self-hosted-runner mode, before senechal removed the guard

```
$ gh api repos/hf7y-estate/senechal/actions/runners
{"total_count":0,"runners":[]}
$ gh pr view 1012 --repo hf7y-estate/senechal --json state,mergedAt,createdAt
{"createdAt":"2026-09-23T11:39:54Z","mergedAt":"2026-10-05T17:29:53Z", ...}
$ gh pr view 999 --repo hf7y-estate/senechal --json state,mergedAt,createdAt
{"createdAt":"2026-09-23T05:20:23Z","mergedAt":null,"state":"CLOSED", ...}
```

`secretaire`'s own `prose.yml` header names why `self-hosted` was chosen at
all: *"this repo is PRIVATE and hf7y's hosted minutes are refused, so the
required check could not start at all. Nine siblings took this
2026-08-20."* The fix for one dead end (no hosted minutes on a private repo)
produced a second dead end (no self-hosted runner registered) -- #1012 and
#1014 sat 12 days with the check unresolved and were merged anyway; #999,
opened the same week, was closed un-merged instead.

### The ignored-while-working mode

```
$ gh pr view 445 --repo hf7y-estate/wtul --json body -q .body
...
The check was red on the last four merged PRs here (#438, #439, #440, #442)
and on #444:
    state-prose-lint -- 40 state-describing line(s) of 1615 considered, baseline 36
```

Five merged PRs, one real (non-zero-run) red reading, zero of them stopped.

### Never a GitHub-enforced gate, anywhere sampled

```
$ gh api repos/hf7y-estate/crt/branches/main/protection -q '.required_status_checks'
(empty)
$ gh api repos/hf7y-estate/realisateur/branches/main/protection -q '.required_status_checks'
{"contexts":["suites"], ...}
$ gh api repos/hf7y-estate/etalon/branches/main/protection -q '.required_status_checks'
(empty)
$ gh api repos/hf7y-estate/groc-mangr/branches/main/protection
{"message":"Upgrade to GitHub Pro or make this repository public to enable this feature.","status":403}
```

No sampled repo required `prose` or `state_prose` to merge. The 11 repos
still carrying the guard are all private, where this org cannot configure
branch protection at all. A check that is not wired into branch protection
cannot block a merge by construction -- every "ignored" outcome above is
that, working as the platform actually allows, not a bypass.

## What shape replaces it

Two measured defects, from #92's own framing, both confirmed above:

**Defect 1 -- a guard that grades the tree punishes the PR that didn't cause
it.** `markdown-cost.sh --census` already solved this for itself: it reads
the merge-base tree and reports the branch's own delta
(`bin/markdown-cost.sh:426-449`), not just the live total.
`state-prose-lint.sh` has no equivalent -- its own quoted wtul reading above
is a raw tree count. Carrying the same merge-base-delta framing into
`state-prose-lint.sh` would stop a PR from reading red for debt that landed
before it branched, without weakening what it catches.

**Defect 2 -- a red check that gates nothing teaches agents to ignore red.**
This is not a bug in any one guard; it is structural on every repo sampled
(no `required_status_checks` entry, no branch protection on private repos
at all). No amount of fixing `prose.yml`'s `uses:` line changes that. The
fix is to stop asking 20+ repos to each keep a workflow file correctly
pointed at etalon's current org forever -- the exact class of bug that
produced the startup-failure row above -- and stop pretending a per-PR call
is "required" when the platform cannot enforce it for most of this org's
repos.

The replacement etalon already has the pieces for: `will-it-run.sh` and
`unreached-audit.sh` both read another repo from the outside, over `gh`,
with no workflow installed in the target at all. The same pattern reads a
repo's prose/state-prose/mechanism-budget numbers on etalon's own schedule
instead of the target repo's PR trigger. When a repo's own numbers cross a
threshold -- the ratchet broken for N days, or (now directly measurable)
the guard can't even start -- etalon files or updates one issue naming the
specific finding in that repo, the same escalation shape #47 already wants
for a different rule. A repo clears the issue; nothing is asked of its next
PR until its numbers say otherwise.

## What etalon becomes

Etalon stops being a required-but-broken PR dependency that every calling
repo has to keep a workflow file correctly pointed at, and becomes what
#79 already named: a periodic auditor that reads every repo's tree from
the outside on its own schedule, grades it with the diff-aware framing
`markdown-cost.sh` already proved against its own merge base, and only
touches a repo -- by filing or updating one issue, never a standing per-PR
CI call -- when that repo's own numbers say it is unhealthy.

<!-- DEFERRED -->
- hf7y-estate/etalon#79 -- the audit/thermostat infrastructure this proposal extends
- hf7y-estate/etalon#47 -- the same file-one-issue escalation shape, for REPLACES: enforcement
- hf7y-estate/groc-mangr#388 -- open disagreement with #77's retire ruling; this report surfaces it, does not resolve it
- hf7y-estate/etalon#20, #21 -- state-prose-lint's causal mode and markdown-cost's merge-base framing this proposal wants state-prose-lint to borrow
<!-- /DEFERRED -->

<!-- DELIVERS -->
- none
<!-- /DELIVERS -->
