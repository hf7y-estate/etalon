# étalon

The reference standard this estate measures itself against. The following
live here, and they live **only** here:

- **`bin/markdown-cost.sh`** — the prose guard. Prices what a diff adds and
  holds the tree against a ratchet that only falls.
- **`bin/state-prose-lint.sh`** — prose describing state, not mechanism.
- **`bin/mechanism-budget.sh`** — a new mechanism must be paid for.
- **`bin/lib/exit-codes.sh`** — the exit vocabulary. `EXIT_BLIND` and friends,
  so the number is one edit rather than twenty-one.

## Using the guard

Six lines in any repo, forever:

```yaml
name: prose
on: [pull_request]
jobs:
  prose:
    uses: hf7y/etalon/.github/workflows/guard.yml@main
```

That is the whole integration. No script is copied, no ratchet is ported, no
credential is needed. Optional inputs: `ratchet` (default `.prose-ratchet`)
and `ref` (default `main` — pin it to freeze a repo against a known étalon).

The **first run seeds** the ratchet from your tree and prints it; commit that
file and the next run has a floor.

## Why this repo exists

**A guard that has copies has versions.** Zach, 2026-08-17: *"Can this guard be
universal in the ecosystem and only maintained in one place."* One copy, called
by reference: no port step to forget, no drift to detect.

## Why public

A reusable workflow's *file* travels to the caller, but the repo holding it is
never checked out — so the script has to be fetchable, and `GITHUB_TOKEN` is
scoped to the calling repo. The alternative was distributing a cross-repo
credential estate-wide, which is the sprawl hf7y/realisateur#171 exists to
reduce.

This repo holds a lint, its tests, and a list of integers. No host layout, no
account names, no paths, no configuration.

## Per-repo baseline, per-estate guard

The **number** is local — each repo's `.prose-ratchet` is its own floor, seeded
where that repo actually is, so adopting the guard never fails on arrival. The
**measurement** is not local. That split is the point: a shared bar nobody can
meet gets disabled, and a private measurement drifts.

## The exit vocabulary

`bin/lib/exit-codes.sh`. The distinction that carries the weight is **BLIND vs
OK**: *"I looked and found nothing"* and *"I could not look"* are different
answers, and this estate's recorded pathology is the second being reported as
the first. A guard that cannot tell must exit `EXIT_BLIND`, never `EXIT_OK`.

The numbers are the **verb ladder**'s, decided by Zach 2026-08-18
(hf7y/realisateur#334) so that guards and the bashified verbs speak one
vocabulary:

| | name | meaning |
|---|---|---|
| 0 | `EXIT_OK` | the question was asked; no findings |
| 1 | `EXIT_FINDING` | it looked and found something |
| 2 | `EXIT_USAGE` | the caller is wrong; nothing was measured |
| 3 | `EXIT_NEEDS_SUMMON` | contracted, no mechanism yet, no spend authorised |
| 4 | `EXIT_GAP` | SHOULD DO — in scope, unbuilt. `--summon` is legitimate |
| 5 | `EXIT_BROKEN` | it ran and answered wrongly |
| 6 | `EXIT_BLIND` | it could not read its domain. Never clean |
| 7 | `EXIT_REFUSED` | WON'T DO — out of scope on principle. No summon lifts it |

8 and above are project-specific and documented in that tool's EXIT STATUS —
ecosim's `sonde` adds 8 WARN and 9 CRIT. They are never a redefinition of one
of the above.
