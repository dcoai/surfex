defmodule Surfex.SourceScan.Registered do
  @moduledoc false
  # Registered process names (§6.7, #299): a module alias the source uses as a process
  # name, `name: MyApp.Sessions`, names something real even when no module has that name.
  # Read from source, never configured.

  @doc """
  Every registered name in the files `globs` match under `root`, sorted: each literal
  alias in a keyword pair `name: Alias` anywhere in the source, in a call or a child-spec
  tuple alike, minus each name a `defmodule` there defines. `{:global, …}`, `{:via, …}`,
  a variable and `__MODULE__` (a real module) are not literal aliases.
  """
  @spec names(String.t(), [String.t()]) :: [String.t()]
  def names(root, globs) do
    texts =
      for glob <- globs,
          file <- Path.wildcard(Path.join(root, glob)),
          uniq: true,
          do: {file, File.read!(file)}

    # Only a file that says `name:` can register one, so the rest are not parsed.
    registered =
      for {file, text} <- texts,
          String.contains?(text, "name:"),
          name <- registrations(Code.string_to_quoted!(text, file: file)),
          uniq: true,
          do: name

    defined = defined(texts, registered)

    registered
    |> Enum.reject(&MapSet.member?(defined, &1))
    |> Enum.sort()
  end

  defp registrations(ast) do
    {_, found} =
      Macro.prewalk(ast, [], fn
        {:name, {:__aliases__, _, parts}} = node, acc ->
          if Enum.all?(parts, &is_atom/1),
            do: {node, [Enum.map_join(parts, ".", &Atom.to_string/1) | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    found
  end

  # The modules defined in the files that could define a registered name: a module's
  # last segment is in its file's text, nested or not.
  defp defined(_texts, []), do: MapSet.new()

  defp defined(texts, registered) do
    lasts = registered |> Enum.map(&(&1 |> String.split(".") |> List.last())) |> Enum.uniq()

    for {file, text} <- texts,
        String.contains?(text, "defmodule"),
        Enum.any?(lasts, &String.contains?(text, &1)),
        name <- modules(Code.string_to_quoted!(text, file: file), []),
        into: MapSet.new(),
        do: name
  end

  # Every module's full name, a nested one as Elixir names it.
  defp modules({:defmodule, _, [{:__aliases__, _, parts}, [do: body]]}, prefix) do
    if Enum.all?(parts, &is_atom/1) do
      name = prefix ++ parts
      [Enum.map_join(name, ".", &Atom.to_string/1) | modules(body, name)]
    else
      modules(body, prefix)
    end
  end

  defp modules({_form, _meta, args}, prefix) when is_list(args),
    do: Enum.flat_map(args, &modules(&1, prefix))

  defp modules(list, prefix) when is_list(list), do: Enum.flat_map(list, &modules(&1, prefix))
  defp modules({a, b}, prefix), do: modules(a, prefix) ++ modules(b, prefix)
  defp modules(_leaf, _prefix), do: []
end
