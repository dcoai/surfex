# Using surfex as a library

Some projects use surfex for one thing: a **surface golden**, a committed document generated
from a source scan, listing what the code declares, which CI regenerates and byte-compares
so it can't disagree with the code. They call two modules directly and keep no relation log.
Both are **supported library API** (spec §23).

## The two modules

- `Surfex.SourceScan` reads Elixir source without compiling it:
  - `lib_sources/1`: the project's own `lib/**/*.ex`, skipping `deps/`, `_build/`, `test/`,
    `tmp/` and hidden directories;
  - `defmodules/1`: the modules in a quoted file;
  - `defs/1` and `types/1`: the public definitions and types of a module, each with its
    version;
  - `module_hash/1`: a module's public surface as one version. The relation log's module
    items also cover the module's hidden definitions, and each item the code of the
    `@moduledoc false` modules it runs (spec §3.3); this function doesn't, so a surface
    golden changes only with the surface;
  - `definition_hash/1`: the version of any node or snippet: a SHA-256 over its AST with
    metadata removed, so a blank line or a comment above it doesn't change it;
  - `project_root/1,2`, `line_range/1` and `hidden_module?/1`.
- `Surfex.Golden` renders a golden from a plain data spec (`t:Surfex.Golden.spec/0`):
  - `render/1`;
  - `stat/2` and `stat_line/2` for its stats lines;
  - `natural_key/1` for ordering rows.

  The renderer owns the notation, so every project's goldens read the same way, and it
  never emits a timestamp, so a golden is a pure function of source. A backticked cell
  reads back as its text under GFM even when the text holds `|` or a backtick; a
  `{:raw, …}` or plain-string cell is written verbatim, so escape a `|` in it as `\|`.

## A surface golden in a few lines

```elixir
rows =
  for file <- Surfex.SourceScan.lib_sources(root),
      {:defmodule, _, [name, _]} = mod <-
        file |> File.read!() |> Code.string_to_quoted!() |> Surfex.SourceScan.defmodules(),
      d <- Surfex.SourceScan.defs(mod),
      do: %{
        "Function" => {:code, "#{Macro.to_string(name)}.#{d.name}/#{d.arity}"},
        "Version" => {:version, d.hash}
      }

Surfex.Golden.render(%{
  name: "API_SURFACE.md",
  purpose: "Every public function, with its version.",
  task: "my_app.surface",
  gate: "surface",
  hardness: :hard,
  columns: ["Function", "Version"],
  rows: rows
})
```

CI runs the task with `--check`, regenerating and comparing. A difference fails the build,
and the diff shows the reviewer exactly which definitions changed.

## The stability promise

- **Signatures:** the documented functions and types of both modules keep their names,
  arities and return shapes. They have since v0.1.0. A test in surfex pins the documented
  surface, so a change is deliberate.
- **Hashes:** `definition_hash/1` gives the same version for the same code from release to
  release, so a golden doesn't churn on an upgrade.
- **Changes:** a change to either module never comes in a patch release. It comes in a minor
  release, listed in the CHANGELOG under "Changed" and marked for library users. One such
  change already: `lib_sources/1` started skipping `test/`, `tmp/` and hidden directories.

A project scanner, such as one giving the blocks a DSL declares as items, is written against
`Surfex.Scanner` and `Surfex.Item`, and the same promise covers them (spec §23.1): the
callbacks and fields keep their names and shapes, and anything added is optional or has a
default.

## Stating your own API as contracts

A library that keeps a relation log can hold its public API to its spec the same way. A
contract fence states a module's signatures in the spec (spec §11.1): each `@spec`,
`@callback` or `@macrocallback` line in it is a unit of its own, keyed by the function it
states.

````markdown
<!-- surfex: contract module: MyLib.Feed -->
```elixir
# The entries since cursor, oldest first, and the cursor to ask from next.
@spec since(cursor, keyword) :: {[entry], cursor}
```
````

Relate each contract to its function (`mix surfex.relate`) and validate it with a test that
calls it. A callback's contract relates to its callback, an item of its own keyed
`MyLib.Store.callback:fetch/1` (spec §5.2.1), validated by judgement since a declaration
has no behaviour for a run to exercise. The relation then dangles when the signature
changes, and also when the function's or callback's `@doc` changes (spec §13.18), so the
spec and the docs can't drift apart unnoticed. Use the marker before a plain `elixir` fence, as here: an `elixir contract` info
string reads the same, but ex_doc renders it as text.

Surfex does this for its own library API. Spec §23.1.1 and §23.2 state the functions and
callbacks above as contracts, and a test checks that they and the pinned API list the same
functions, each with the `@spec` the code declares.

## This isn't adoption

A surface golden says what the code declares. Surfex's purpose is keeping a spec, its tests
and its code aligned, which needs the relation log. When a project depends on surfex but
has no `.surfex/`, `mix surfex.info` says so. `mix surfex.info adoption` covers starting
the log on an existing project.
