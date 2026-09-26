defmodule Surfex.Gate do
  @moduledoc """
  The write-or-check step every golden shares, so no project writes it again.

  A golden is a pure function of source. The gate either writes the fresh render
  (`--write`) or compares it with the committed bytes and says what changed. The
  comparison reads the committed file, not a re-derivation: it is the committed bytes
  that are being checked.
  """

  @doc """
  Writes `golden` to `path` when `write?`; otherwise checks the file against it. Returns
  the failures, one message each: `[]` when the file is current or was just written.
  `command` is what regenerates it, quoted back to the reader.
  """
  @spec run(String.t(), String.t(), String.t(), boolean) :: [String.t()]
  def run(path, golden, command, write?) do
    name = Path.basename(path)

    cond do
      write? ->
        File.write!(path, golden)
        []

      not File.exists?(path) ->
        ["#{name} does not exist. Run `#{command} --write`."]

      message = drift(File.read!(path), golden) ->
        ["#{name}: #{message}\nRegenerate with `#{command} --write` once the source is right."]

      true ->
        []
    end
  end

  @doc """
  Evaluates a `.surfex.exs`-style data file, which must return a keyword list. Raises
  naming the file when it is missing or is not one.
  """
  @spec config!(String.t()) :: keyword
  def config!(path) do
    unless File.exists?(path), do: raise(ArgumentError, "#{path} does not exist")
    {config, _binding} = Code.eval_file(path)

    unless Keyword.keyword?(config),
      do: raise(ArgumentError, "#{path} must evaluate to a keyword list")

    config
  end

  @doc """
  What changed between a committed golden and a fresh render, or `nil` when they are
  identical: the rows that changed, appeared or went. A row is keyed by its table's
  `Item` column, or its first column when the table has none. A changed row that has a
  `Cited by` cell names the sections citing it: the sections to revisit. A change outside
  every row is reported as such.
  """
  @spec drift(String.t(), String.t()) :: String.t() | nil
  def drift(same, same), do: nil

  def drift(old, new) do
    old_rows = rows(old)
    new_rows = rows(new)

    changed =
      for {item, {value, cites}} <- Enum.sort(new_rows),
          match?({:ok, {v, _}} when v != value, Map.fetch(old_rows, item)),
          do: changed(item, cites)

    added = new_rows |> Map.keys() |> Kernel.--(Map.keys(old_rows)) |> Enum.sort()
    gone = old_rows |> Map.keys() |> Kernel.--(Map.keys(new_rows)) |> Enum.sort()

    other =
      if changed == [] and added == [] and gone == [],
        do: ["\nNo row changed: the prose or a stats line did.\n"],
        else: []

    # Only a golden that relates rows to a spec (a `Cited by` column) says what the spec
    # has to do about a change.
    traced = Enum.any?(Map.values(new_rows) ++ Map.values(old_rows), &(elem(&1, 1) != nil))

    IO.iodata_to_binary([
      "out of date.\n",
      section(title(traced, "Changed", "the sections listed cite them — revisit each"), changed),
      section(title(traced, "Added", "nothing in the spec covers them yet"), added),
      section(title(traced, "Gone", "the spec may still describe them"), gone),
      other
    ])
  end

  defp title(true, what, why), do: "#{what} (#{why})"
  defp title(false, what, _why), do: what

  defp changed(item, nil), do: item
  defp changed(item, cites) when cites in ["", "—"], do: "#{item} (uncited)"
  defp changed(item, cites), do: "#{item} → #{cites}"

  defp section(_title, []), do: []
  defp section(title, lines), do: ["\n#{title}:\n", Enum.map(lines, &"  #{&1}\n")]

  # key => {version (or the whole row when there is no Version column), cited-by | nil}
  defp rows(text) do
    text
    |> String.split("\n")
    |> Enum.reduce({%{}, nil}, fn line, {acc, header} ->
      cells = if String.starts_with?(line, "|"), do: cells(line), else: nil

      cond do
        cells == nil -> {acc, nil}
        header == nil -> {acc, cells}
        Enum.all?(cells, &(&1 =~ ~r/^:?-+:?$/)) -> {acc, header}
        true -> {record(acc, header, cells), header}
      end
    end)
    |> elem(0)
  end

  defp record(acc, header, cells) do
    row = Enum.zip(header, cells)
    by_name = Map.new(row)
    key = Map.get(by_name, "Item") || row |> hd() |> elem(1)
    value = if v = by_name["Version"], do: unquote_code(v), else: Enum.join(cells, " | ")
    cites = if c = by_name["Cited by"], do: unquote_code(c)
    Map.put(acc, unquote_code(key), {value, cites})
  end

  defp cells(line) do
    line
    |> String.trim()
    |> String.trim_leading("|")
    |> String.trim_trailing("|")
    |> String.split(" | ")
    |> Enum.map(&String.trim/1)
  end

  defp unquote_code("`" <> rest), do: String.trim_trailing(rest, "`")
  defp unquote_code(text), do: text
end
