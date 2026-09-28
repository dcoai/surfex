defmodule Surfex.Scan.Classes do
  @moduledoc """
  The class scanner: one `Surfex.Scan` record of kind `:class` per class in `.surfex.exs`.

  A **class** names a kind of code the spec deliberately doesn't describe (plumbing,
  callbacks, generated functions) and says why: `classes: [{"plumbing", "process
  wiring, not behaviour"}]`. **Rules** say which items fall into it:
  `rules: [%{class: "plumbing", kinds: [:function], name: ~r/^handle_/}]`. These are the
  profile's keys (`Surfex.Profile`), validated the same way.

    * **id** — the class's name
    * **hash** — over its reason and every rule naming it (kinds, name pattern,
      `parent_cited`), in any order. Rewording the reason or changing a rule changes it,
      so every `excuses` relation of the class dangles until someone confirms each item
      still belongs.
    * **location** — `.surfex.exs`, with no lines: the config is evaluated data.

  Pure: a function of the config alone.
  """

  alias Surfex.{Profile, Scan, SourceScan}

  @doc "One record per class in `config`, sorted by name. Raises on an invalid config."
  @spec records(keyword | map) :: [Scan.t()]
  def records(config) do
    %{classes: classes, rules: rules} = Profile.coverage!(config)

    classes
    |> Enum.map(fn {name, reason} ->
      mine =
        for %{class: ^name} = rule <- rules do
          [Enum.sort(rule.kinds), rule.name && Regex.source(rule.name), rule.parent_cited]
        end

      %Scan{
        kind: :class,
        id: name,
        hash: SourceScan.definition_hash(Macro.escape([reason, Enum.sort(mine)])),
        location: %{file: ".surfex.exs", lines: nil}
      }
    end)
    |> Enum.sort_by(& &1.id)
  end
end
