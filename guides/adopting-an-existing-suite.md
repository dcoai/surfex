# Adopting an existing suite

Surfex's process (spec §18) assumes new work: a test is written, fails, and passes once
the code exists, and that red→green is the evidence a relation rests on. An established
project's tests already pass. They can't honestly go red, so without help every relation
would need a review before Surfex reports anything useful, and again after each refactor.

`adoption:` in `.surfex.exs` decides how much of the existing suite is taken on trust
(spec §18.1).

## Trust or re-evaluate

| Setting | Use it when |
|---|---|
| `:reevaluate` (the default) | the suite is new, small, or nobody can vouch for it; or the project wants every relation earned |
| `:trust` | the suite has been kept honest for a long time: written test-first, reviewed, run in CI on every change |
| `[trust: globs, reevaluate: globs]` | a well-kept core beside tests nobody has read in a while |

Per area, the globs lie within `tests:` and don't overlap. A test matched by neither is
re-evaluated:

```elixir
adoption: [trust: ["test/core/**/*_test.exs"], reevaluate: ["test/legacy/**/*_test.exs"]]
```

Trust is a statement about the tests, so make it where you'd defend it. Re-evaluating a
test later is always possible. Trusting more later is not.

## The baseline

Under trust, adoption is: tag, run green, take the baseline.

```
# 1. Write @tag verifies: on the tests that verify each spec unit: the review work.
mix test
mix surfex.baseline --note "test-first since 2023, reviewed in every MR"
mix surfex.confirm --evidence
```

**Tag first.** The baseline adopts the `verifies:` tags already written; it doesn't create
them, and it is one-shot. A tag added afterwards is an ordinary claim, proposed until its
test fails and passes or someone reviews it, one at a time. So the tags decide what the
baseline is worth. With none, `mix surfex.baseline` refuses, unless `--no-tags` says
you mean to baseline test versions alone and tag later at that per-tag cost. It ends by
reporting what it adopted: the trusted test versions, the `verifies` relations, and the
spec units left without one.

**What it is.** A record, per trusted test version, that the version counts as if it had
discriminated, plus that test's `verifies:` tags as relations with basis `baseline`.
`confirm --evidence` then carries the code each baselined test exercises (`implements`,
basis `baseline`). The note says why the suite is trusted; it stays in the log.

**What it isn't.**
- It isn't evidence: reports count baseline relations separately, naming the mode.
- It isn't repeatable: it is one-shot, so widening `adoption:` later trusts nothing new.
- It doesn't vouch for tests that aren't green at the time it is taken. Surfex refuses
  until they are.

## From trust to evidence

The baseline only shrinks. Each relation leaves it the first time its test
discriminates for real: a run that fails and then passes against different code, at the
same test version. `confirm --evidence` records that red→green, and the relation moves to
basis `evidence`. Ordinary bug-fix work does this over time. Nothing has to be scheduled.

When the backlog should end, `mix surfex.status --no-baseline` (or `baseline: :fail` in
`.surfex.exs`) fails while any relation still rests on the baseline.

## What changes cost afterwards

| Change | Trusted test | Re-evaluated test |
|---|---|---|
| Refactor the code, tests still green | `confirm --evidence` re-confirms it as `baseline`; no review | it needs a red→green, or a review (`mix surfex.validate`) |
| Edit the test | the new version isn't baselined: a red→green, or a review | the same |
| Change the spec unit | review the test against the new text, as always | the same |
| A test's first red→green | its relations move to `evidence` | the same |
| Narrow `adoption:` | its baseline relations are reported unvalidated: the backlog to review | — |
| Add a test | the normal process: fails first, then passes | the same |

Trust only saves work on the most common change, a refactor under green tests. Everything
else costs what it would without adoption.
