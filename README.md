# Surfex

Surfex keeps a specification, its tests and LLM-generated code in sync, by making the work
of keeping them in sync the only way to pass.

It hashes every section of your spec, every test and every public function, reading source
without compiling it, and keeps a log of which versions of them were **shown** to belong
together. Code is never taken on anyone's word. It counts as implementing a section when a
test that verifies the section failed against the old code and passes against the new, or
when a reviewed test passes against it. When anything changes, its relations **dangle**
until that's shown again. A fresh clone knows exactly what has and hasn't been validated,
CI fails on anything that hasn't, and an agent gets the precise work list. The log never
loses anything, so it is also the history of how the spec, the tests and the code came to
relate.

## Installation

Surfex is a build-time tool with no dependencies of its own:

```elixir
def deps do
  [
    {:surfex, github: "dcoai/surfex", tag: "v0.4.0", only: [:dev, :test], runtime: false}
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

- **Commit the state for review:** `goldens: [:status]` in `.surfex.exs` makes
  `mix surfex.goldens` gate `RELATIONS.md`, a readable record of every relation and its
  state.
- **Feed an agent:** `mix surfex.status --format json` lists every relation needing
  attention, with the recorded and current hashes of each end and where each end is.
- **Relate by hand:** `mix surfex.relate FROM TO --type T` for anything the spec doesn't
  name. Types are `implements`, `refines`, `depends_on`, `tests`, `verifies` and `excuses`.
  Naming a pair validates nothing: an `implements` relation is proposed until the process
  validates it.
- **Put a relation to rest:** `mix surfex.retire FROM TO --type T`.
- **Rename a section:** give headings anchors (`## Totals {#totals}`) and they keep their
  id. Otherwise `mix surfex.suggest` spots the rename, or `mix surfex.move OLD NEW` carries
  the relations across.
- **Work in parallel:** the log is merged by git's union merge (set up by `--init`). If
  two branches confirm the same relation without seeing each other, it shows as
  **conflicted**, and `mix surfex.resolve … --pick` settles it.
- **Ask how it got here:** `mix surfex.history MyApp.Cart.total/1` lists every relation
  it has had, from the log alone.

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
work.

[`spec.md`](spec.md) is the full specification: the scan records, the relation log, every
state and command, and every `.surfex.exs` key. Surfex holds it to its own code with its
own relation log, and CI runs `mix surfex.status`.

Hashes ignore layout: moving code, reformatting it, or reflowing a paragraph changes
nothing, and a function's hash covers the private helpers it calls. Goldens never contain
dates, and any misconfiguration fails loudly before anything is written.

MIT licensed.
