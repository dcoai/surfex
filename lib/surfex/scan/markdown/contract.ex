defmodule Surfex.Scan.Markdown.Contract do
  @moduledoc false
  # Contract fences (§11.1): a fenced block of typespecs, one unit per signature.
  #
  # A fence is a contract when the line `<!-- surfex: contract [module: M] -->` stands
  # before it, or when its info string is `elixir contract`. Each `@spec`, `@callback` or
  # `@macrocallback` in it is one signature, keyed `Module.name/arity` (a callback
  # `Module.callback:name/arity`) by the module §11.9 resolves; several signatures of one
  # function (a multi-clause spec) are one unit. Where a signature ends is §11.8's: by its
  # delimiters, not its indentation.

  @marker ~r/^ {0,3}<!--\s*surfex:\s*contract(?:\s+module:\s*(\S+))?\s*-->\s*$/
  @signature ~r/^(\s*)@(spec|callback|macrocallback)\b/
  # A line that opens the next typespec attribute, which no signature runs into.
  @head ~r/^\s*@(spec|callback|macrocallback|type|typep|opaque)\b/
  # A `defmodule M do` line of the fence, and an `end` that may close it (§11.9).
  @defmodule ~r/^(\s*)defmodule\s+([A-Z]\w*(?:\.[A-Z]\w*)*)\s+do\s*(?:#.*)?$/
  @closer ~r/^(\s*)end\s*(?:#.*)?$/
  # A module alias written alone in backticks, as a heading names its module.
  @backticked ~r/`([A-Z]\w*(?:\.[A-Z]\w*)*)`/
  # A qualified function in backticks, `M.f/3` or `M.f`, which names M for f (§11.14).
  @qualified ~r/`([A-Z]\w*(?:\.[A-Z]\w*)*)\.([a-z_]\w*[?!]?)(?:\/(\d+))?`/

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
  the order each first appears, as `%{key, contract, first, last, body}`, and the lines that
  belong to no signature. `fence` is the marker's module, or the headings around the fence
  (`headings/4`). A signature's module is its head's, else the `defmodule` around it in the
  fence, else the marker's, else the one the headings place it in (§11.9, §11.14).
  `{:error, number, why}` for a signature that doesn't parse or that nothing places.
  """
  @spec signatures([{String.t(), pos_integer}], String.t() | headings) ::
          {:ok, [map], [{String.t(), pos_integer}]} | {:error, pos_integer, String.t()}
  def signatures(lines, fence) do
    {groups, rest} = split(lines, [], [], [])

    Enum.reduce_while(groups, {:ok, [], Enum.reverse(rest)}, fn {group, kind, around},
                                                                {:ok, acc, rest} ->
      [{_, first} | _] = group
      text = Enum.map_join(group, "\n", &elem(&1, 0))

      with {:ok, name, own} <- key(text),
           {:ok, module} <- module(own || around || fence, name) do
        {_, last} = List.last(group)

        sig = %{
          key: "#{module}.#{prefix(kind)}#{name}",
          contract: "#{module}.#{name}",
          first: first,
          last: last,
          body: Enum.map(group, &elem(&1, 0))
        }

        {:cont, {:ok, [sig | acc], rest}}
      else
        {:error, why} -> {:halt, {:error, first, why}}
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
  #
  # `mods` is the stack of `defmodule`s open at a line, `{indent, module}`, innermost
  # first: a nested one joins its parent's name, and an `end` at its column closes it.
  defp split([], groups, rest, _mods), do: {Enum.reverse(groups), rest}

  defp split([{line, _} = numbered | lines], groups, rest, mods) do
    case Regex.run(@signature, line, capture: :all_but_first) do
      [indent, kind] ->
        {group, lines} = extend([numbered], line, String.length(indent), lines)
        around = with [{_, module} | _] <- mods, do: module, else: (_ -> nil)
        split(lines, [{group, kind, around} | groups], rest, mods)

      nil ->
        split(lines, groups, [numbered | rest], modules(line, mods))
    end
  end

  defp modules(line, mods) do
    case Regex.run(@defmodule, line, capture: :all_but_first) do
      [indent, name] ->
        name = with [{_, parent} | _] <- mods, do: "#{parent}.#{name}", else: (_ -> name)
        [{String.length(indent), name} | mods]

      nil ->
        case {Regex.run(@closer, line, capture: :all_but_first), mods} do
          {[indent], [{at, _} | outer]} -> if String.length(indent) == at, do: outer, else: mods
          _ -> mods
        end
    end
  end

  defp module(module, _name) when is_binary(module), do: {:ok, module}

  # Nearest heading first: one naming this function (`M.f/a`, `M.f`) places it in M; one
  # naming modules places it in its one module. A heading naming only other functions
  # places nothing, but it is remembered: if the code has the function only in its module,
  # keying it from an outer heading would be a silent mis-key, so it is an error.
  defp module(%{headings: headings, code: code}, name) do
    [fun, arity] = String.split(name, "/")
    arity = String.to_integer(arity)

    headings
    |> Enum.reduce_while(nil, fn h, nearer ->
      case h.functions |> Enum.filter(&names?(&1, fun, arity)) |> Enum.map(&elem(&1, 0)) do
        [_ | _] = ms -> {:halt, one(Enum.uniq(ms), name)}
        [] -> placed(h, nearer)
      end
    end)
    |> case do
      {:outer, module, _from, nil} -> {:ok, module}
      {:outer, module, from, nearer} -> conflict(module, from, nearer, fun, arity, code)
      {:ok, _} = ok -> ok
      {:error, _} = error -> error
      _nothing -> one([], name)
    end
  end

  defp placed(%{modules: [_ | _] = modules} = h, nearer) do
    case modules do
      [module] -> {:halt, {:outer, module, h, nearer}}
      several -> {:halt, one(several, nil)}
    end
  end

  defp placed(%{functions: [_ | _]} = h, nil), do: {:cont, h}
  defp placed(_h, nearer), do: {:cont, nearer}

  defp names?({_module, fun, at}, fun, arity), do: at in [nil, arity]
  defp names?(_function, _fun, _arity), do: false

  defp one([module], _name), do: {:ok, module}

  defp one([], _name),
    do:
      {:error,
       "names no module: qualify it, wrap it in a defmodule, give module: or put it under a heading that names one (§11.9)"}

  defp one(modules, _name),
    do:
      {:error,
       "names no module, and its heading names several, #{Enum.join(modules, ", ")}: qualify it, wrap it in a defmodule or give module:"}

  # The outer module, unless the code says the function is only in a nearer heading's.
  defp conflict(module, _from, _nearer, _fun, _arity, nil), do: {:ok, module}

  defp conflict(module, from, nearer, fun, arity, code) do
    name = "#{fun}/#{arity}"

    there =
      nearer.functions |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.reject(&(&1 == module))

    case {code.("#{module}.#{name}"), Enum.filter(there, &code.("#{&1}.#{name}"))} do
      {nil, [other | _]} ->
        {:error,
         "`#{name}` would be keyed `#{module}.#{name}` from the heading at line #{from.line}, " <>
           "but only `#{other}`, which the nearer heading at line #{nearer.line} names, has " <>
           "`#{name}`: mark the fence module: (§11.14)"}

      _ ->
        {:ok, module}
    end
  end

  # A callback is keyed apart from a function of the same name (§11.9).
  defp prefix("spec"), do: ""
  defp prefix(kind), do: kind <> ":"

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
  # Grouping by the qualified key keeps two modules' functions of one name apart.
  defp merge(sigs) do
    sigs
    |> Enum.group_by(& &1.key)
    |> Enum.map(fn {_key, [one | _] = same} ->
      %{one | last: List.last(same).last, body: Enum.flat_map(same, & &1.body)}
    end)
    |> Enum.sort_by(& &1.first)
  end

  # `name/arity` of a typespec's head, read by parsing it as Elixir, and the module the head
  # names (`nil` for none).
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
    {:ok, "#{name}/#{length(List.wrap(args))}", Enum.join(parts, ".")}
  end

  defp head({:"::", _, [{name, _, args}, _return]}) when is_atom(name),
    do: {:ok, "#{name}/#{length(List.wrap(args))}", nil}

  defp head(_spec), do: {:error, "has no `name(args) :: return` head"}

  @typedoc "What the headings around a fence name, deepest first, and the code's names."
  @type headings :: %{
          headings: [
            %{
              text: String.t(),
              line: pos_integer,
              modules: [String.t()],
              functions: [{String.t(), String.t(), non_neg_integer | nil}]
            }
          ],
          code: (String.t() -> String.t() | nil) | nil
        }

  @doc """
  What each heading enclosing a contract fence in `file` names (`headings`, `{text, line}`
  deepest first), for `signatures/2` to place a signature by (§11.9, §11.14): its modules,
  the items a profile subject (§6.6) gives it, else the module aliases written alone in
  backticks; and its functions, each qualified function in backticks (`M.f/3`, `M.f`) as
  `{module, name, arity}`, the module the code defines it in when `code` knows it, else M
  as written.
  """
  @spec headings(
          [map],
          String.t(),
          [{String.t(), pos_integer}],
          (String.t() -> String.t() | nil) | nil
        ) ::
          headings
  def headings(subjects, file, headings, code) do
    %{
      headings:
        for {text, line} <- headings do
          %{
            text: text,
            line: line,
            modules: named(subjects, file, text),
            functions: functions(text, code)
          }
        end,
      code: code
    }
  end

  defp named(subjects, file, heading) do
    case Enum.flat_map(subjects, &items(&1, file, heading)) do
      [] -> @backticked |> Regex.scan(heading, capture: :all_but_first) |> List.flatten()
      items -> items
    end
    |> Enum.uniq()
  end

  defp functions(heading, code) do
    for [module, fun | arity] <- Regex.scan(@qualified, heading, capture: :all_but_first) do
      arity = with [a] <- arity, do: String.to_integer(a), else: (_ -> nil)
      written = if arity, do: "#{module}.#{fun}/#{arity}", else: "#{module}.#{fun}"
      {(code && code.(written)) || module, fun, arity}
    end
  end

  defp items(%{file: file, heading: heading, items: items}, path, text) do
    if file_matches?(file, path) and Regex.match?(heading, text), do: items, else: []
  end

  defp file_matches?(file, path) when is_binary(file), do: file == path
  defp file_matches?(re, path), do: Regex.match?(re, path)
end
