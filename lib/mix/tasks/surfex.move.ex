defmodule Mix.Tasks.Surfex.Move do
  @shortdoc "Move every relation of an id that was renamed onto its new id"

  @moduledoc """
  Moves every live relation of `OLD` onto `NEW` (`Surfex.Record.move/5`): for each, a
  `retire` of the old relation and a `relate` of the same type with `NEW` in its place.

      mix surfex.move "spec.md#Carts/Adding items" "spec.md#cart-add"
      mix surfex.move "spec.md#Totals" "spec.md#Carts/Totals" --note "moved under Carts"

  Use it when a heading is renamed, an anchor added, or a section moved. The moved end
  keeps the version recorded for `OLD`, so a move never confirms anything: if the text
  changed as it moved, the relation dangles until you confirm it. `mix surfex.suggest`
  proposes moves it can see (the same version under a new id).

  Moving a test (a renamed module, `describe` or file) also carries its `red_green` and
  `baseline` records, when its version is unchanged. Any it leaves behind are listed: the
  test changed, so it earns them again.
  """

  use Mix.Task

  alias Surfex.Record.Mix, as: R

  @impl Mix.Task
  def run(args) do
    {opts, ids} = R.parse(args)
    {old, new} = R.two!(ids)
    {root, scans, entries, meta} = R.context(opts)
    R.record(root, Surfex.Record.move(scans, entries, old, new, meta))

    for left <- Surfex.Record.left_behind(scans, entries, old, new) do
      Mix.shell().info(
        "not carried: #{left.type} for version #{left.hash}, but #{new} is at #{left.now}: " <>
          "the test changed, so it earns this again"
      )
    end
  end
end
