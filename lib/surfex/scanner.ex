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
  """

  @doc """
  Every item under `root`, each with a stable key and a content hash that ignores
  position and layout (see `Surfex.SourceScan.definition_hash/1`). `file` is relative to
  `root`. `opts` is the scanner's own configuration.
  """
  @callback items(root :: String.t(), opts :: keyword) :: [Surfex.Item.t()]
end
