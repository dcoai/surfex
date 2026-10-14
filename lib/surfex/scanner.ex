defmodule Surfex.Scanner do
  @moduledoc """
  Finds the items the code declares: the code records the relation log relates
  (`Surfex.Scan.code/1`), and what the spec's citations resolve to. A scanner knows one
  language's declarations; it knows nothing about any spec, and `Surfex.Cite` knows
  nothing about any language.

  `Surfex.Scanner.Elixir` is built in. A project whose code is in another language (a C
  reference implementation, a protocol described in headers) implements `c:items/2` for
  it (`scanner:` in `.surfex.exs`) and gets the rest unchanged.

  A scanner should read source, never compile or load it: a check built on it then runs
  before, and independently of, the code it inspects, and cannot be fooled by a module
  that failed to build.

  Several scanners combine (`scanners:` in `.surfex.exs`, spec §5.3): a project keeps the
  Elixir scanner and adds its own, and one key from two scanners is an error.

  ## DSL items

  In a project built with a DSL, behaviour is declared in blocks inside a module (an
  action, a policy) that no `def` names. A scanner for the DSL gives each block as a
  `Surfex.Item` (spec §4.1), filled so the rest of surfex works unchanged:

    * `kind` — the DSL's own (`:action`, `:policy`, …)
    * `parent` — the declaring module, and `name` the DSL's name for the block, so the key
      is `Module.name`: unique in the module, stable across edits that rename nothing
    * `hash` — `Surfex.SourceScan.definition_hash/1` over the block's AST, so a change to
      the block changes its version and no sibling's
    * `lines` — the block's span; `calls` — the keys of what the block references, so
      reach goes on into them
    * `shape` — `true` for a declaration with no behaviour of its own (an attribute)
    * `hidden` and `runs` stay empty: a DSL item carries no hidden definitions. Its block
      is its whole definition and its hash covers it

  Surfex depends on no DSL: the project, or a companion package, writes the scanner, with
  `Surfex.SourceScan` to read source.

  ## Stability

  This behaviour and `Surfex.Item` are supported API (spec §23.1): the callbacks keep their
  names, arities and shapes, a callback added later is optional, and a change to either
  comes in a minor release, listed under "Changed" in the CHANGELOG.
  """

  @doc """
  Every item under `root`, each with a stable key and a content hash that ignores
  position and layout (see `Surfex.SourceScan.definition_hash/1`). `file` is relative to
  `root`. `opts` is the scanner's own configuration.
  """
  @callback items(root :: String.t(), opts :: keyword) :: [Surfex.Item.t()]
end
