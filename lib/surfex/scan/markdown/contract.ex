defmodule Surfex.Scan.Markdown.Contract do
  @moduledoc false
  # Contract fences (§11.1): a fenced block of typespecs, one unit per signature.
  #
  # A fence is a contract when the line `<!-- surfex: contract [module: M] -->` stands
  # before it, or when its info string is `elixir contract`. Each `@spec`, `@callback` or
  # `@macrocallback` in it, with the lines indented under it, is one signature, keyed
  # `name/arity`; several signatures of one function (a multi-clause spec) are one unit.

  @marker ~r/^ {0,3}<!--\s*surfex:\s*contract(?:\s+module:\s*(\S+))?\s*-->\s*$/
  @signature ~r/^(\s*)@(spec|callback|macrocallback)\b/

  @doc "A contract marker's module (`nil` when it names none), or `:none` for any other line."
  @spec marker(String.t()) :: String.t() | nil | :none
  def marker(line) do
    case Regex.run(@marker, line, capture: :all_but_first) do
      nil -> :none
      [] -> nil
      [module] -> module
    end
  end

  @doc "Whether a fence's info string opens a contract."
  @spec info?(String.t() | nil) :: boolean
  def info?(info), do: info != nil and String.split(info) == ["elixir", "contract"]

  @doc """
  The signatures among a fence's content lines (`{line, number}`), grouped by function in
  the order each first appears, as `%{key, first, last, body}`, and the lines that belong
  to no signature. `{:error, number, why}` for a signature that doesn't parse.
  """
  @spec signatures([{String.t(), pos_integer}]) ::
          {:ok, [map], [{String.t(), pos_integer}]} | {:error, pos_integer, String.t()}
  def signatures(lines) do
    {groups, rest} = split(lines, [], [])

    Enum.reduce_while(groups, {:ok, [], Enum.reverse(rest)}, fn group, {:ok, acc, rest} ->
      [{_, first} | _] = group
      text = Enum.map_join(group, "\n", &elem(&1, 0))

      case key(text) do
        {:ok, key} ->
          {_, last} = List.last(group)

          {:cont,
           {:ok,
            [%{key: key, first: first, last: last, body: Enum.map(group, &elem(&1, 0))} | acc],
            rest}}

        {:error, why} ->
          {:halt, {:error, first, why}}
      end
    end)
    |> case do
      {:ok, sigs, rest} -> {:ok, merge(Enum.reverse(sigs)), rest}
      error -> error
    end
  end

  # Each signature line opens a group that takes the following lines indented deeper.
  defp split([], groups, rest), do: {Enum.reverse(Enum.map(groups, &Enum.reverse/1)), rest}

  defp split([{line, _} = numbered | lines], groups, rest) do
    case Regex.run(@signature, line, capture: :all_but_first) do
      [indent, _kind] ->
        {more, lines} = Enum.split_while(lines, &continues?(&1, String.length(indent)))
        split(lines, [Enum.reverse([numbered | more]) | groups], rest)

      nil ->
        split(lines, groups, [numbered | rest])
    end
  end

  defp continues?({line, _}, indent) do
    String.trim(line) != "" and
      String.length(line) - String.length(String.trim_leading(line)) > indent
  end

  # Several signatures of one function are one unit, at its first signature's place.
  defp merge(sigs) do
    sigs
    |> Enum.group_by(& &1.key)
    |> Enum.map(fn {_key, [one | _] = same} ->
      %{one | last: List.last(same).last, body: Enum.flat_map(same, & &1.body)}
    end)
    |> Enum.sort_by(& &1.first)
  end

  # `name/arity` of a typespec's head, read by parsing it as Elixir.
  defp key(text) do
    case Code.string_to_quoted(text) do
      {:ok, {:@, _, [{_kind, _, [spec]}]}} -> head(spec)
      {:ok, _other} -> {:error, "is not one typespec"}
      {:error, {_meta, message, token}} -> {:error, "doesn't parse: #{inspect(message)}#{token}"}
    end
  end

  defp head({:when, _, [spec, _guards]}), do: head(spec)

  defp head({:"::", _, [{name, _, args}, _return]}) when is_atom(name),
    do: {:ok, "#{name}/#{length(List.wrap(args))}"}

  defp head(_spec), do: {:error, "has no `name(args) :: return` head"}

  @doc """
  The module a contract fence in `file` is about, by the profile's `subjects:` (§6.6): the
  items of the nearest enclosing heading (`headings`, deepest first) that a subject matches.
  `{:ok, module}`, `{:error, items}` when it names several, or `nil` when none matches.
  """
  @spec subject([map], String.t(), [String.t()]) ::
          {:ok, String.t()} | {:error, [String.t()]} | nil
  def subject(subjects, file, headings) do
    Enum.find_value(headings, fn heading ->
      case Enum.flat_map(subjects, &items(&1, file, heading)) do
        [] -> nil
        [module] -> {:ok, module}
        several -> {:error, several}
      end
    end)
  end

  defp items(%{file: file, heading: heading, items: items}, path, text) do
    if file_matches?(file, path) and Regex.match?(heading, text), do: items, else: []
  end

  defp file_matches?(file, path) when is_binary(file), do: file == path
  defp file_matches?(re, path), do: Regex.match?(re, path)
end
