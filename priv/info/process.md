# The process

A relation is shown, not asserted. For new or changed behaviour:

```
1. the spec unit changes, or has no relation
2. a failing test for it: write it, or find the existing one; tag it
     @tag verifies: "hint-id"         (or "spec.md#anchor")
3. mix test                           # it fails: that run is evidence
4. mix surfex.suggest --accept --note "…"   # records the verifies, on the failing run
5. write the code until the test is green
6. mix test && mix surfex.confirm --evidence   # records tests + implements: red, then green
7. mix surfex.status
```

Evidence is the test's red run against one version of the code and its green run against
another, at the same test version. `Surfex.ExUnitFormatter` in `test/test_helper.exs`
records each run in `_build/surfex/evidence.jsonl`; the red→green itself is kept in the log,
so it survives a clean checkout.

**What each change needs afterwards:**

| Change | Relations | What to do |
|---|---|---|
| Code refactored, tests green | `implements`, `tests` dangle | `mix test && mix surfex.confirm --evidence` |
| Code changed behaviour | the same, and maybe a test fails | fix the code, or the spec first |
| Test edited | its relations dangle; the new version must earn its red | make it fail first, or review it (`validate`) |
| Spec unit reworded, same behaviour | `verifies` dangle | `mix surfex.confirm TEST UNIT --type verifies --note …` (judgement) |
| Spec unit changed behaviour | `verifies` and `implements` dangle | update the test (it fails), then the code (green), then `confirm --evidence` |
| Spec wrong, tests and code agree with it | none | `mix surfex.mark UNIT --needs-update` |
| Id renamed | orphaned | `mix surfex.move OLD NEW` (anchors `{#id}` avoid this) |
| Thing removed | orphaned | `mix surfex.retire FROM TO --type T` |

A spec unit may be verified by one test or by several; add or remove tests as the unit
needs. Planned and new items don't fail the check; unvalidated ones fail only under
`--validated`.
