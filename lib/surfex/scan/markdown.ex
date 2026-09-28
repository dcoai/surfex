defmodule Surfex.Scan.Markdown do
  @moduledoc """
  The spec scanner for markdown: one `Surfex.Scan` record per section.

  A **section** is a heading and the lines under it, up to the next heading of any level.
  Its subsections are sections of their own, so an edit to §3.2 changes §3.2's version and
  not §3's. Text before the first heading is the section `(preamble)`, when it has any.

    * **id** — the file and the path of headings down to it:
      `spec.md#Carts/Adding items`. Two sections with the same path in one file are told
      apart by a suffix, `~2`, `~3`, in order.
    * **hash** — over the section's own body, **not its heading**, with runs of whitespace
      collapsed. Rewording the body changes it; renaming the heading, reflowing a
      paragraph or adding blank lines doesn't. A renamed heading keeps its version under a
      new id, which is what lets a tool recognise the move.
    * **location** — the file, from the heading's line to the section's last line.

  A line inside a fenced code block is never a heading; the block is part of the body.
  """

  alias Surfex.Scan

  @doc "Every section of every markdown file matching `globs` under `root`, in order."
  @spec records(String.t(), [String.t()]) :: [Scan.t()]
  def records(root, globs) do
    root = Path.expand(root)

    globs
    |> Enum.flat_map(&Path.wildcard(Path.join(root, &1)))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(fn path ->
      file = Path.relative_to(path, root)
      path |> File.read!() |> sections(file)
    end)
  end

  @doc "The sections of one markdown text, as records located in `file`."
  @spec sections(String.t(), String.t()) :: [Scan.t()]
  def sections(text, file) do
    text
    |> String.split("\n")
    |> Enum.with_index(1)
    |> split()
    |> Enum.reject(&(&1.heading == nil and blank?(&1.body)))
    |> number_duplicates()
    |> Enum.map(fn s ->
      %Scan{
        kind: :spec,
        id: "#{file}##{s.path}",
        hash: hash(s.body),
        location: %{file: file, lines: {s.first, s.last}}
      }
    end)
  end

  # Sections in order: %{heading, path, first, last, body: [line]}. The heading stack gives
  # each section its path; a fence switches heading detection off until it closes.
  defp split(lines) do
    start = %{heading: nil, path: "(preamble)", first: 1, last: 1, body: []}

    {sections, current, _stack, _fence} =
      Enum.reduce(lines, {[], start, [], false}, fn {line, no}, {done, current, stack, fence} ->
        heading = if fence, do: nil, else: heading(line)

        cond do
          heading != nil ->
            {level, text} = heading
            stack = [{level, text} | Enum.drop_while(stack, fn {l, _} -> l >= level end)]
            path = stack |> Enum.reverse() |> Enum.map_join("/", &elem(&1, 1))
            next = %{heading: text, path: path, first: no, last: no, body: []}
            {[current | done], next, stack, fence}

          true ->
            fence = if String.starts_with?(line, "```"), do: not fence, else: fence
            current = %{current | body: [line | current.body], last: last(current, line, no)}
            {done, current, stack, fence}
        end
      end)

    [current | sections]
    |> Enum.reverse()
    |> Enum.map(&%{&1 | body: Enum.reverse(&1.body)})
  end

  # A section's last line is its last non-blank line, so trailing blank lines before the
  # next heading are not counted as its content.
  defp last(current, line, no), do: if(String.trim(line) == "", do: current.last, else: no)

  defp heading(line) do
    case Regex.run(~r/^(#+)\s+(.+?)\s*#*\s*$/, line, capture: :all_but_first) do
      [hashes, text] -> {String.length(hashes), text}
      _ -> nil
    end
  end

  defp blank?(body), do: Enum.all?(body, &(String.trim(&1) == ""))

  defp number_duplicates(sections) do
    {numbered, _seen} =
      Enum.map_reduce(sections, %{}, fn s, seen ->
        n = Map.get(seen, s.path, 0) + 1
        path = if n == 1, do: s.path, else: "#{s.path}~#{n}"
        {%{s | path: path}, Map.put(seen, s.path, n)}
      end)

    numbered
  end

  # Whitespace carries no meaning in prose: collapse it, so reflowing a paragraph or adding
  # blank lines is not a change.
  defp hash(body) do
    body
    |> Enum.join("\n")
    |> String.split()
    |> Enum.join(" ")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 8)
  end
end
