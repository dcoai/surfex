# Surfex

Surfex keeps a specification, its tests and its code in step, and makes doing that work
the only way to pass.

It reads every section of the spec, every test and every public function, and keeps a
log of which versions of them were **shown** to belong together. Code is never taken on
anyone's word, a person's or an LLM's: it counts as implementing the spec when a test
for that part of the spec failed and then passed against it, or a reviewed test passes
against it. When the spec, a test or the code changes, what it touched needs showing
again, and Surfex says exactly what and why. A fresh clone knows what has and hasn't been
validated, CI fails on anything that hasn't, and an agent gets a precise work list.

## What it handles

- **Keeping spec, tests and code in step** as any of them changes: a refactor, a new test,
  a reworded or changed requirement, a renamed section or function.
- **Validating rather than asserting:** each relation records how it was shown, by test
  evidence, a review or a judgement, and a claim nobody has shown never passes.
- **Test-first work by agents:** the spec unit, then a failing test, then the code, with
  each step recorded as it happens.
- **Adopting an established project:** a long-kept suite can be taken on trust once,
  then earns evidence over time, or every test can be re-evaluated from scratch.
- **A spec that's wrong in use:** when the tests and code agree with the spec but the
  result is wrong, the spec itself is marked for change.
- **Coverage you can hold a line on:** how much of the spec, tests and code is covered by
  validated relations, and what each missing item lacks.
- **Found work handed on:** problems Surfex finds become change drafts for the project's
  own process, and can be filed in its tracker.
- **Reviewable, mergeable history:** a committed, append-only log that merges across
  branches, flags parallel disagreements, and answers how anything came to relate.
- **Committed reports:** the relation status and the coverage report kept as files that CI
  checks for drift.

How to do each: `mix surfex.info` lists the topics and commands, and the guides cover
writing specs and adopting an existing suite.

## Installation

Surfex is a build-time tool with no dependencies of its own:

```elixir
def deps do
  [
    {:surfex, github: "dcoai/surfex", tag: "v0.5.0", only: [:dev, :test], runtime: false}
  ]
end
```

## A worked example

The code, and the spec that describes it:

```elixir
# lib/my_app/cart.ex
defmodule MyApp.Cart do
  @moduledoc "A shopping cart."

  @doc "An empty cart."
  def new, do: []

  @doc "Adds `qty` of `item`."
  def add(cart, item, qty \\ 1), do: [{item, qty} | cart]

  @doc "The number of items in the cart."
  def total(cart), do: Enum.reduce(cart, 0, fn {_item, qty}, sum -> sum + qty end)
end
```

```markdown
# Carts

`MyApp.Cart` holds what a customer is buying. `MyApp.Cart.new/0` starts an empty one.

## Adding items

`MyApp.Cart.add` puts `qty` of an item in the cart, one by default.

## Totals

`MyApp.Cart.total/1` counts the items.
```

Tell Surfex where the spec and the tests are, and record test runs as evidence:

```elixir
# .surfex.exs
[
  sources: ["spec.md"],
  tests: ["test/**/*_test.exs"],
  require: [code: [:implements], test_hint: [:verifies]]
]

# test/test_helper.exs
ExUnit.start(formatters: [ExUnit.CLIFormatter, Surfex.ExUnitFormatter])
```

Then work by the process, one spec unit at a time. Say `Totals` is new:

1. **The spec says what to check.** A test hint under the section:

   ````markdown
   ```test totals-counts
   an empty cart totals 0; a cart holding 2 of one item and 1 of another totals 3
   ```
   ````

2. **A failing test.** Write it from the hint, tag it, and run it. It fails, because
   `total/1` doesn't exist yet:

   ```elixir
   @tag verifies: "totals-counts"
   test "total counts every item" do
     assert Cart.total([]) == 0
     assert Cart.total([{:apple, 2}, {:pear, 1}]) == 3
   end
   ```

3. **The test relation.** `mix surfex.suggest --accept` records that the test verifies the
   hint, on its failing run, and that the section names `total/1`. That second relation is
   *proposed*: a claim, not yet validated.
4. **The code**, until the test passes.
5. **The code relation.** The test went red against the old code and green against the
   new: that is the validation.

   ```sh
   mix test && mix surfex.confirm --evidence
   mix surfex.status
   ```

`mix surfex.status` now passes for `Totals`: its code relation is current, validated by
the red run and the green one, and the log's entry says so.

Later someone rewrites `total/1`, keeping its behaviour. The relations dangle, the test
still passes, and the same `mix test && mix surfex.confirm --evidence` re-validates them.
Nothing is revalidated by hand while the tests keep passing. If the spec changes instead,
the test changes first (it must fail again), then the code.

There is no way to say code is implemented without this. `mix surfex.confirm` never
confirms an `implements` relation, and a suggestion validates nothing. For relations that
existed before, `mix surfex.validate TEST SPEC_UNIT --note …` records a review: you read
the test against the spec unit, fixed it where it fell short, and it passes.

## Beyond the example

`mix surfex.info` is the map of everything else, from the installed version: the model,
the process and what each change needs, reading the status, recording and validating
relations, marks, adoption, completeness, change drafts, goldens and every `.surfex.exs`
key. Each topic is one command away (`mix surfex.info process`).

## Upgrading from the v0.2 trace

The trace (`mix surfex.trace`, `SPEC_TRACE.md`) was removed in 0.4.0; the relation log
replaces it. Its checks all live on: citations become suggested `implements` relations,
excusing classes become `excuses` relations, uncited code is **unmet** under `require:`,
and a citation of something that doesn't exist fails `mix surfex.status`. To move a project
over, delete the trace-only keys from `.surfex.exs` (Surfex names them), replace `:trace`
in `goldens:` with `:status`, then run `mix surfex.log --init` and
`mix surfex.suggest --accept`.

## Reference

[`guides/writing-specs.md`](guides/writing-specs.md) is how to write a spec Surfex relates
well: section sizing, stable headings, naming the code, checkable claims, and test-first
work. [`guides/adopting-an-existing-suite.md`](guides/adopting-an-existing-suite.md) is
when to trust an established suite and what that costs.

[`spec.md`](spec.md) is the full specification: the scan records, the relation log, every
state and command, and every `.surfex.exs` key. Surfex holds it to its own code with its
own relation log, and CI runs `mix surfex.status`.

Hashes ignore layout: moving code, reformatting it, or reflowing a paragraph changes
nothing, and a function's hash covers the private helpers it calls. Goldens never contain
dates, and any misconfiguration fails loudly before anything is written.

MIT licensed.
