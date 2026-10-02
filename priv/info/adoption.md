# Adoption: trust or re-evaluate

An established suite already passes, so its tests can't honestly go red, and without help
every relation would need a review first. `adoption:` in `.surfex.exs` decides:

- `:reevaluate` (default): nothing is trusted; every relation is earned by the process.
- `:trust`: the existing tests may be adopted once, by a baseline.
- `[trust: globs, reevaluate: globs]`: by area; globs within `tests:`, not overlapping.

Tag first, then take the baseline once, after a green run:

```
# 1. Write @tag verifies: on the tests that verify each spec unit.
mix test
mix surfex.baseline --note "why this suite is trusted"
mix surfex.confirm --evidence
```

The baseline adopts the tags already written; a tag added later is an ordinary claim,
validated on its own. With no tags it refuses, unless `--no-tags`. It reports the trusted
test versions, the `verifies` adopted and the spec units left without one.

It records each trusted test version as if it had discriminated, plus its `verifies:`
tags, with basis `baseline`; `confirm --evidence` then carries `implements` through those
tests as `baseline`. It refuses under `:reevaluate`, a second time, and before the
trusted tests are green.

Trust only shrinks:
- a refactor under green trusted tests re-confirms as `baseline`, no review needed;
- an edited test's new version isn't trusted;
- a test's first red→green moves its relations to `evidence`;
- narrowing `adoption:` leaves their relations unvalidated: the backlog to review.

Status counts baseline relations with the mode; `--no-baseline` fails on them. The guide
*Adopting an existing suite* covers when to trust.
