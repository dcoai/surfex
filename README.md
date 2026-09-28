# Surfex

Surfex keeps a specification and LLM-generated code in sync.

It hashes every section of your spec and every public function of your code, reading
source without compiling it, and keeps a log of which versions of them someone confirmed
belong together. When either side changes, the relation **dangles** until someone looks
at it again and confirms it, by name. A fresh clone knows exactly what has and hasn't been
reconciled, CI fails on anything that hasn't, and an agent gets the precise work list:
this function changed, and these spec sections describe it. The log never loses anything,
so it is also the history of how the spec and the code came to relate.

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

Tell Surfex where the spec is, and that every public function must implement a section of
it:

```elixir
# .surfex.exs
[
  sources: ["spec.md"],
  require: [code: [:implements]]
]
```

Start the log, and let Surfex propose the relations the spec already implies (each section
paired with the code it names). `--accept` records them:

```sh
mix surfex.log --init
mix surfex.suggest --accept
mix surfex.status
```

```
relation status: ok
  implements: current 5

```

Now someone rewrites `total/1`. `mix surfex.status`, which is also the CI check, fails
and says exactly what to look at:

```
relation status: FAILING
  implements: current 4 · dangling 1

Dangling (an end changed since it was confirmed):
  implements  code MyApp.Cart.total/1 ↔ spec spec.md#Carts/Totals (changed: MyApp.Cart.total/1 (lib/my_app/cart.ex:12-12))

** (Mix) relations need attention (see above)
```

Only `total/1`'s relation dangles: a function's body is its own, so the module's relation
stays current. Read the section against the new code, fix whichever side is wrong, and
confirm what you checked:

```sh
mix surfex.confirm MyApp.Cart.total/1 --note "same count, simpler"
```

A relation only becomes current again when someone names it. Regenerating something can't
clear it, so an agent can't clear it by accident. A spec edit dangles relations the same
way, from the other side.

## Beyond the example

- **Commit the state for review:** `goldens: [:status]` in `.surfex.exs` makes
  `mix surfex.goldens` gate `RELATIONS.md`, a readable record of every relation and its
  state.
- **Feed an agent:** `mix surfex.status --format json` lists every relation needing
  attention, with the recorded and current hashes of each end and where each end is.
- **Relate by hand:** `mix surfex.relate FROM TO --type T` for anything the spec doesn't
  name. Types are `implements`, `refines`, `depends_on`, `tests` and `excuses`.
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
