defmodule Surfex.Cite.Contracts do
  @moduledoc false
  # §6.9: a contract unit's function is a citation. Its key, `Module.name/arity` (§11.9),
  # is the most literal claim a spec makes about the code, so it is resolved against the
  # code items as a cited name is (§6.4), and one naming nothing is a broken citation.
  #
  # The module a signature is about is §11.9's, decided by the spec scan; this reads the
  # contract records it made, so the two never disagree.

  alias Surfex.{Cite, Item, Profile, Scan}

  # A callback item's name within its module, `callback:name/arity` (§5.2.1).
  @callback_name ~r/^(?:macro)?callback:/

  @doc """
  One citation per contract unit of `scans` that isn't deferred, directly or by a unit it
  sits in (§13.6, §13.13), resolved against `items` under `profile`, sorted by file and
  line. Its `span` is the contract (`Module.name/arity`), its section `(contract)`, its line
  the signature's first. An unresolved one carries `why`: no such module, no such function
  in it, or the function at other arities only; an external one, its `known_external` reason.
  """
  @spec citations([Scan.t()], [Item.t()], Profile.t()) :: [Cite.t()]
  def citations(scans, items, %Profile{} = profile) do
    index = Cite.index(items, profile)
    families = families(items)
    listing = listing_callbacks(items)
    by_id = for %Scan{kind: :spec} = s <- scans, into: %{}, do: {s.id, s}

    for %Scan{kind: :spec, role: :contract} = unit <- scans,
        not deferred?(unit, by_id) do
      {status, found, why} = resolve(unit, index, {families, listing}, profile)

      %{
        span: unit.contract,
        kind: :subject,
        file: unit.location.file,
        section: "(contract)",
        line: elem(unit.location.lines, 0),
        status: status,
        items: found
      }
      |> then(&if(why, do: Map.put(&1, :why, why), else: &1))
    end
    |> Enum.sort_by(&{&1.file, &1.line, &1.span})
  end

  @doc """
  The code's function names for the spec scan (§11.14): a function from a name as a
  heading writes it, `M.f/3` or `M.f`, to the module the code defines that function in, or
  `nil`. The name is rewritten by `rewrites` (the profile's `normalise`) first, then looked
  up as an item key or an alias, as a citation is (§6.4).
  """
  @spec code([Item.t()], [{Regex.t(), String.t()}]) :: (String.t() -> String.t() | nil)
  def code(items, rewrites) do
    names =
      for %Item{parent: parent} = item <- items,
          is_binary(parent),
          name <- [Item.key(item) | item.aliases],
          into: %{},
          do: {name, parent}

    fn written ->
      name =
        Enum.reduce(rewrites, String.trim(written), fn {re, to}, s -> Regex.replace(re, s, to) end)

      Map.get(names, name)
    end
  end

  @typedoc "A citation of an arity no contract states, and the contracts stating others."
  @type cited_arity :: %{
          citation: Cite.t(),
          function: String.t(),
          stated: [
            %{unit: String.t(), arity: non_neg_integer, file: String.t(), line: pos_integer}
          ]
        }

  @doc """
  §13.15: each citation in `citations` of `Module.name/arity` that names no code
  (`:unresolved`) where the contract units among `scans` state `Module.name` at other
  arities only, with those units sorted by file and line. It reads the spec alone, so it
  holds with no code scanned.
  """
  @spec arities([Cite.t()], [Scan.t()]) :: [cited_arity]
  def arities(citations, scans) do
    stated =
      for %Scan{kind: :spec, role: :contract, contract: contract} = unit <- scans,
          [_, function, arity] <- [Regex.run(~r/^(.+)\/(\d+)$/, contract)],
          do:
            {function,
             %{
               unit: unit.id,
               arity: String.to_integer(arity),
               file: unit.location.file,
               line: elem(unit.location.lines, 0)
             }}

    by_function = Enum.group_by(stated, &elem(&1, 0), &elem(&1, 1))

    for %{status: :unresolved, span: span} = c <- citations,
        [_, function, arity] <- [
          Regex.run(~r/^([A-Z][\w.]*\.[^.\/\s]+)\/(\d+)$/, String.trim(span))
        ],
        {:ok, others} <- [Map.fetch(by_function, function)],
        not Enum.any?(others, &(&1.arity == String.to_integer(arity))) do
      %{citation: c, function: function, stated: Enum.sort_by(others, &{&1.file, &1.line})}
    end
  end

  @doc "What a spec-shape warning of `arities/2`'s entry says."
  @spec arity_text(cited_arity) :: String.t()
  def arity_text(%{citation: c, function: function, stated: stated}) do
    at = Enum.map_join(stated, ", ", &"#{function}/#{&1.arity} at #{&1.file}:#{&1.line}")
    "`#{String.trim(c.span)}` cites an arity no contract states; the contracts state #{at}"
  end

  # The modules the scanners list callbacks of (§5.2.1): a callback contract of one of them
  # resolves to its callback item or is broken, never to the module.
  defp listing_callbacks(items) do
    for %Item{parent: parent, name: name} <- items,
        is_binary(parent),
        Regex.match?(@callback_name, name),
        into: MapSet.new(),
        do: parent
  end

  # `Module.name` => the arities the code defines it at; a callback is no arity of a
  # function.
  defp families(items) do
    for %Item{parent: parent, name: name} <- items,
        is_binary(parent),
        not Regex.match?(@callback_name, name),
        [_, fun, arity] <- [Regex.run(~r/^(.+)\/(\d+)$/, name)],
        reduce: %{} do
      acc -> Map.update(acc, "#{parent}.#{fun}", [arity], &[arity | &1])
    end
  end

  defp deferred?(%Scan{deferred: d}, _by_id) when d != nil, do: true

  defp deferred?(%Scan{} = unit, by_id) do
    [unit.within, unit.under]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.any?(fn id ->
      case Map.fetch(by_id, id) do
        {:ok, parent} -> deferred?(parent, by_id)
        :error -> false
      end
    end)
  end

  defp resolve(
         %Scan{contract: contract, id: id, location: %{file: file}},
         index,
         {families, listing},
         p
       ) do
    [_, module, fun, arity] = Regex.run(~r/^(.+)\.([^.]+)\/(\d+)$/, contract)
    callback = callback_key(id)

    cond do
      Enum.any?([contract, "#{module}.#{fun}"], &Map.has_key?(p.documented_absences, {&1, file})) ->
        {:documented_absence, [], nil}

      external =
          Enum.find([contract, "#{module}.#{fun}", module], &Map.has_key?(p.known_external, &1)) ->
        {:external, [], Map.fetch!(p.known_external, external)}

      callback != nil and Map.has_key?(index, callback) ->
        found(Map.fetch!(index, callback))

      # A module whose callbacks the scanners list has no callback of this name.
      callback != nil and MapSet.member?(listing, module) ->
        [_, kind] = Regex.run(~r/\.((?:macro)?callback):/, callback)

        {:unresolved, [],
         "names nothing the code has: no #{kind} `#{fun}/#{arity}` in `#{module}`"}

      # A scanner that lists none of the module's callbacks: checked as far as its
      # behaviour module.
      callback != nil and Map.has_key?(index, module) ->
        found(Map.fetch!(index, module))

      callback == nil and Map.has_key?(index, contract) ->
        found(Map.fetch!(index, contract))

      not Map.has_key?(index, module) ->
        {:unresolved, [], "names nothing the code has: no module `#{module}`"}

      arities = Map.get(families, "#{module}.#{fun}") ->
        at =
          arities
          |> Enum.map(&String.to_integer/1)
          |> Enum.sort()
          |> Enum.map_join(", ", &"/#{&1}")

        {:unresolved, [],
         "names nothing the code has: `#{module}.#{fun}` exists at #{at}, not /#{arity}"}

      true ->
        {:unresolved, [], "names nothing the code has: no `#{fun}` in `#{module}`"}
    end
  end

  # A callback's own key, `Module.callback:name/arity` (§11.9), or nil for a function's.
  defp callback_key(id) do
    case Regex.run(~r/#(.+\.(?:macro)?callback:[^.]+)$/, id, capture: :all_but_first) do
      [key] -> key
      nil -> nil
    end
  end

  defp found([item]), do: {:resolved, [Item.key(item)], nil}
  defp found(many), do: {:ambiguous, many |> Enum.map(&Item.key/1) |> Enum.sort(), nil}
end
