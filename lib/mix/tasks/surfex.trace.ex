defmodule Mix.Tasks.Surfex.Trace do
  @shortdoc "Render (--write) or check the spec↔code trace golden"

  @moduledoc """
  > **Deprecated.** The relation log (`Surfex.Status`, `mix surfex.status`) replaces the
  > trace: it records which versions of the spec and the code were confirmed to belong
  > together, where the trace records only that they cite each other. The trace still
  > works, and `mix surfex.suggest` reads its citations, until a later release removes it.

  Traces the project's spec against its code (`Surfex.Trace`) and gates the result: the
  `:trace` entry of `mix surfex.goldens`, on its own.

      mix surfex.trace            # check: fails on drift, gaps and broken citations
      mix surfex.trace --write    # regenerate the golden, then report the same failures

  The trace is defined in `.surfex.exs` at the project root (`--config PATH` to use
  another). With the built-in Elixir scanner the namespace defaults to the app's name
  camelized (`:my_app` → `MyApp`). A project scanner is project code, so the task compiles
  first; the built-in one reads source and needs no compile.

  **Every failure is reported in one run**, not the first one found: a drift of the
  golden, each GAP, each unresolved or ambiguous citation, and each required section that
  cites nothing. `--write` writes the golden even when there are failures, so they show
  up in its diff, and still exits non-zero.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args), do: Surfex.Goldens.Mix.run(args, :trace, "mix surfex.trace")
end
