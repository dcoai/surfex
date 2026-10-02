---
id: pm-1
title: "Proposal: the test scanner resolves aliases declared inside a test or describe body"
labels: [Proposal]
created: 2026-09-30
gitlab_issue: 87
gitlab_synced: true
---

## Problem

`Surfex.Scan.ExUnit` resolves aliases only at module level. An alias declared inside a
test body (or a describe block) is ignored, so a call through it is recorded under the
short name:

```elixir
test "a" do
  alias MyApp.Cart
  Cart.total([])
end
# calls: ["Cart", "Cart.total/1", "MyApp.Cart"]   (MyApp.Cart.total/1 missing)
```

The module itself is still named, through the `alias` line, but the *function* call isn't
recognised. So the test gets no `tests` relation to `MyApp.Cart.total/1`, and the triangle
reports "calls none of its code" for a test that plainly does.

## Origin

Surfaced twice, independently, while validating by review: #81 (`ChangeTest`'s
`process!/1` test) and #82 (`CompletenessTest`'s `completeness!/1` test). Both used
`alias Surfex.Status.Config` inside the test. The workaround each time was hoisting the
alias to the module top, which is fine, but the scanner shouldn't need it.

**Pre-existing:** reproduced on main with `Surfex.Scan.ExUnit.tests/2` on the snippet
above.

## Deep-dive scope

- **Root cause:** `calls/3` collects aliases from the module body (`names/1`) and
  resolves every body against them, so a lexical alias inside a `test`/`describe` block
  never reaches the resolver.
- **Why undetected:** `ScanExUnitTest`'s calls test declares its aliases at module level.
  Surfex's own tests mostly do too, and the gap only showed as triangle gaps that looked
  like tagging mistakes.

## Proposed change

1. Resolve aliases lexically: an `alias` inside a `describe` applies to that block's
   tests and helpers; one inside a test body applies to that test, from its line on. That
   covers `alias A.B`, `alias A.B, as: C` and `alias A.{B, C}`, as at module level.
2. A test in `ScanExUnitTest` for each form, red first.
3. Spec §11 "What it calls": aliases are resolved where they're declared, module,
   describe or test.
4. Re-validate the relations whose `calls` change (the `tests` relations are refreshed by
   `suggest --accept`).

## Acceptance

- The snippet's calls include `MyApp.Cart.total/1`.
- Tests for module-, describe- and test-level aliases; spec §11 updated.
- A root-cause note on the issue; `mix surfex.status --validated` ok.

### 2026-09-30 — Offline

- GitLab unreachable while filing from #82; sync to a GitLab `Proposal` issue when it's
  back, then update `gitlab_issue:` and `gitlab_synced: true`.

### 2026-09-30 — Synced

- Filed as #87 when GitLab was reachable again.
