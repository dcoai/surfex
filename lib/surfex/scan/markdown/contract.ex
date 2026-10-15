defmodule Surfex.Scan.Markdown.Contract do
  @moduledoc false
  # Contract fences (§11.1): a fenced block of typespecs, one unit per signature.
  #
  # A fence is a contract when the line `<!-- surfex: contract [module: M] -->` stands
  # before it, or when its info string is `elixir contract`. Each `@spec`, `@callback` or
  # `@macrocallback` in it is one signature, keyed `name/arity`, or `Module.name/arity` for
  # a head that names its module; several signatures of one function (a multi-clause spec)
  # are one unit. Where a signature ends is §11.8's: by its delimiters, not its indentation.

  @marker ~r/^ {0,3}<!--\s*surfex:\s*contract(?:\s+module:\s*(\S+))?\s*-->\s*$/
  @signature ~r/^(\s*)@(spec|callback|macrocallback)\b/
  # A line that opens the next typespec attribute, which no signature runs into.
  @head ~r/^\s*@(spec|callback|macrocallback|type|typep|opaque)\b/

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
        {:ok, key, module} ->
          {_, last} = List.last(group)

          {:cont,
           {:ok,
            [
              %{
                key: key,
                module: module,
                first: first,
                last: last,
                body: Enum.map(group, &elem(&1, 0))
              }
              | acc
            ], rest}}

        {:error, why} ->
          {:halt, {:error, first, why}}
      end
    end)
    |> case do
      {:ok, sigs, rest} -> {:ok, merge(Enum.reverse(sigs)), rest}
      error -> error
    end
  end

  # Each signature line opens a group (§11.8): it takes the following lines while its text
  # doesn't parse yet, whatever their indentation, so a closing `}` back at the head's
  # column is its own; once it parses, the lines indented deeper (a `when`, a `| nil`). It
  # never runs into the next typespec attribute, and an unfinished one stops at the fence's
  # end, where key/1 reports it.
  defp split([], groups, rest), do: {Enum.reverse(groups), rest}

  defp split([{line, _} = numbered | lines], groups, rest) do
    case Regex.run(@signature, line, capture: :all_but_first) do
      [indent, _kind] ->
        {group, lines} = extend([numbered], line, String.length(indent), lines)
        split(lines, [group | groups], rest)

      nil ->
        split(lines, groups, [numbered | rest])
    end
  end

  defp extend(group, _text, _indent, []), do: {Enum.reverse(group), []}

  defp extend(group, text, indent, [{line, _} = numbered | more] = lines) do
    takes? =
      not Regex.match?(@head, line) and
        (not parses?(text) or deeper?(line, indent))

    if takes?,
      do: extend([numbered | group], text <> "\n" <> line, indent, more),
      else: {Enum.reverse(group), lines}
  end

  defp parses?(text), do: match?({:ok, _}, Code.string_to_quoted(text))

  defp deeper?(line, indent) do
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

  # A head naming its module (`MyApp.open(…)`) is keyed by it, as written.
  defp head({:"::", _, [{{:., _, [{:__aliases__, _, parts}, name]}, _, args}, _return]})
       when is_atom(name) do
    module = Enum.join(parts, ".")
    {:ok, "#{module}.#{name}/#{length(List.wrap(args))}", module}
  end

  defp head({:"::", _, [{name, _, args}, _return]}) when is_atom(name),
    do: {:ok, "#{name}/#{length(List.wrap(args))}", nil}

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
