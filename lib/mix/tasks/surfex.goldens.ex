defmodule Mix.Tasks.Surfex.Goldens do
  @shortdoc "Render (--write) or check every golden in .surfex.exs"

  @moduledoc """
  Gates every golden the project lists in `.surfex.exs` (`Surfex.Goldens`): the relation
  status (`RELATIONS.md`) and any project goldens (`Surfex.Surface`). One CI line for all
  of them.

      mix surfex.goldens            # check: fails on any drift
      mix surfex.goldens --write    # regenerate every golden, then report the same failures

  `--config PATH` reads another file. The namespace citations are read under defaults to
  the app's name camelized. The project is compiled only when an entry is project code;
  the built-in Elixir scanner reads source and needs no compile.

  **Every failure of every golden is reported in one run.** `--write` writes them all,
  even when some fail, so the failures show up in the diff, and still exits non-zero.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args), do: Surfex.Goldens.Mix.run(args, "mix surfex.goldens")
end
