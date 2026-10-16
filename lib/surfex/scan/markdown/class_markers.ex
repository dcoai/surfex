defmodule Surfex.Scan.Markdown.ClassMarkers do
  @moduledoc false
  # Class and deferral markers (§11.7, §13.13), and the class patterns a section matches.

  import Surfex.Scan.Markdown.Lines, only: [fail: 3, own_marker?: 1]

  @class_marker ~r/^ {0,3}<!--\s*surfex:\s*class\s+(\S.*?)\s*-->\s*$/
  @deferred_marker ~r/^ {0,3}<!--\s*surfex:\s*deferred\s+(\S.*?)\s*-->\s*$/
  @comment ~r/^ {0,3}<!--\s*(.*?)\s*-->\s*$/
  @class_name ~r/^([A-Za-z0-9_-]+)(?:\s*:\s*(\S.*))?$/
  @deferral ~r/^([^\s:]+)(?:\s*:\s*(\S.*))?$/
  @issue_ref ~r/^(?:[A-Za-z0-9_.-]+(?:\/[A-Za-z0-9_.-]+)*)?#\d+$/
  # A deferral citing a spec unit (§13.13): the reference (no `:` or `@`), an optional
  # `@VERSION` pin and an optional reason.
  @unit_deferral ~r/^([^:@]*[^:@\s])\s*(?:@(\S+?))?(?:\s*:\s*(\S.*))?$/
  @pin ~r/^[0-9a-f]{8}$/

  # ── Classes and deferrals (§11.7) ───────────────────────────────────────

  # A class or deferral marker on this line, as `{st, marker}`: `{:class, name, note, by}`,
  # `{:deferred, ref, reason}` or `{:deferred_unit, ref, pin, reason}` (§13.13), or nil. A
  # malformed one is a scan error and `:malformed`, never section text.
  def class_line(st, line, no) do
    cond do
      match = Regex.run(@class_marker, line, capture: :all_but_first) ->
        [text] = match

        case Regex.run(@class_name, text, capture: :all_but_first) do
          [name] -> declared(st, no, name, nil)
          [name, note] -> declared(st, no, name, note)
          nil -> malformed(st, no, "a class marker is <!-- surfex: class NAME[: REASON] -->")
        end

      match = Regex.run(@deferred_marker, line, capture: :all_but_first) ->
        [text] = match

        {ref, reason} =
          case Regex.run(@deferral, text, capture: :all_but_first) do
            [ref] -> {ref, nil}
            [ref, reason] -> {ref, reason}
            nil -> {text, nil}
          end

        cond do
          Regex.match?(@issue_ref, ref) -> {st, {:deferred, ref, reason}}
          String.starts_with?(text, "#") -> malformed(st, no, issue_or_unit(ref))
          true -> unit_deferral(st, no, text)
        end

      class = alias_class(st, line) ->
        {st, {:class, class, nil, :alias}}

      true ->
        {st, nil}
    end
  end

  defp malformed(st, no, why), do: {fail(st, no, why), :malformed}

  # A deferral citing a spec unit, `REF[@VERSION][: REASON]` (§13.13): resolved once the
  # whole spec is scanned (`records/4`), so `cites` is nil until then.
  defp unit_deferral(st, no, text) do
    case Regex.run(@unit_deferral, text, capture: :all_but_first) do
      nil ->
        malformed(st, no, issue_or_unit(text))

      [ref | rest] ->
        {pin, reason} =
          case rest do
            [] -> {nil, nil}
            [pin] -> {pin, nil}
            [pin, reason] -> {pin, reason}
          end

        pin = if pin == "", do: nil, else: pin

        if pin != nil and not Regex.match?(@pin, pin),
          do:
            malformed(
              st,
              no,
              "a deferral pins the cited unit's version, 8 lowercase hex characters (REF@1a2b3c4d), got #{inspect(pin)}"
            ),
          else: {st, {:deferred_unit, ref, pin, reason}}
    end
  end

  defp issue_or_unit(ref),
    do:
      "a deferral names its issue, <!-- surfex: deferred #123[: REASON] --> or group/project#123, " <>
        "or cites a spec unit, <!-- surfex: deferred UNIT[@VERSION][: REASON] -->, got #{inspect(ref)}"

  defp declared(st, no, name, note) do
    case Enum.find(st.classes, &(&1.name == name)) do
      nil -> malformed(st, no, "class #{name} isn't declared in spec_classes:")
      class -> {st, {:class, class, note, :marker}}
    end
  end

  # The first class whose `marker:` reads this own-line comment.
  def alias_class(%{classes: []}, _line), do: nil

  def alias_class(st, line) do
    case Regex.run(@comment, line, capture: :all_but_first) do
      [inner] -> Enum.find(st.classes, &(&1.marker != nil and Regex.match?(&1.marker, inner)))
      nil -> nil
    end
  end

  # A marker classes or defers the unit it sits in: the open block (a deferral only), else
  # the section. One class or deferral per unit.
  def class_unit(%{block: block} = st, {:class, _class, _note, _by}, no) when block != nil,
    do:
      fail(
        st,
        no,
        "a class marker classes sections only: it can't sit in block #{block.id} (line #{block.first})"
      )

  def class_unit(%{block: block} = st, {:deferred, _ref, _reason} = marker, no)
      when block != nil,
      do: defer_block(st, deferral(marker, no), no)

  def class_unit(%{block: block} = st, {:deferred_unit, _, _, _} = marker, no)
      when block != nil,
      do: defer_block(st, deferral(marker, no), no)

  # A second class or deferral on a section is an error, and the first stands.
  def class_unit(%{cur: %{class: nil, deferred: nil} = cur} = st, {:class, class, note, by}, no) do
    class = %{name: class.name, reason: class.reason, note: note, by: by, line: no}
    %{st | cur: %{cur | class: class}}
  end

  def class_unit(%{cur: %{class: nil, deferred: nil} = cur} = st, marker, no),
    do: %{st | cur: %{cur | deferred: deferral(marker, no)}}

  def class_unit(%{cur: cur} = st, _marker, no) do
    %{line: line} = cur.class || cur.deferred

    fail(
      st,
      no,
      "the section is already classed or deferred by line #{line}: a unit takes one class or deferral"
    )
  end

  defp defer_block(%{block: block} = st, deferral, no) do
    if block.deferred,
      do: fail(st, no, "block #{block.id} is already deferred (line #{block.deferred.line})"),
      else: %{st | block: %{block | deferred: deferral}}
  end

  # What a deferral marker records: an issue's `%{ref, reason}`, or a unit citation's
  # `%{ref, reason, cites, pin}` (§13.13), each with its line until the scan ends. A
  # citation keeps its line, which a report names where the pin is written.
  defp deferral({:deferred, ref, reason}, no), do: %{ref: ref, reason: reason, line: no}

  defp deferral({:deferred_unit, ref, pin, reason}, no),
    do: %{ref: ref, reason: reason, cites: nil, pin: pin, line: no}

  # A section's class: its marker's, else the first pattern's that matches it. A deferral
  # marker is the unit's own word too, so no pattern classes a deferred section.
  def section_class(%{class: nil, deferred: nil} = s, classes, file),
    do: pattern_class(classes, file, s.heading)

  def section_class(s, _classes, _file), do: marked(s.class)

  # What a record keeps of a marker: everything but its line.
  def marked(nil), do: nil
  def marked(%{cites: _} = citation), do: citation
  def marked(marker), do: Map.delete(marker, :line)

  # The first declared class whose pattern matches a section: `files:` its file, `headings:`
  # its heading as written, both when both are given. A class with neither is no pattern.
  defp pattern_class(classes, file, heading) do
    Enum.find_value(classes, fn class ->
      pattern? = class.files != nil or class.headings != nil

      files? = class.files == nil or Enum.any?(class.files, &glob_match?(&1, file))

      heading? =
        class.headings == nil or (heading != nil and Regex.match?(class.headings, heading))

      if pattern? and files? and heading?,
        do: %{name: class.name, reason: class.reason, note: nil, by: :pattern}
    end)
  end

  @doc false
  # Whether a glob, as `Path.wildcard/1` reads one relative to the root, matches a relative
  # path: `**` any directories, `*` and `?` within one name, `{a,b}` either, `[…]` a class.
  @spec glob_match?(String.t(), String.t()) :: boolean
  def glob_match?(glob, path), do: Regex.match?(glob_regex(glob), path)

  defp glob_regex(glob) do
    source =
      glob
      |> String.graphemes()
      |> glob_source([])
      |> IO.iodata_to_binary()

    Regex.compile!("^" <> source <> "$")
  end

  defp glob_source([], acc), do: Enum.reverse(acc)
  defp glob_source(["*", "*", "/" | rest], acc), do: glob_source(rest, ["(?:.*/)?" | acc])
  defp glob_source(["*", "*" | rest], acc), do: glob_source(rest, [".*" | acc])
  defp glob_source(["*" | rest], acc), do: glob_source(rest, ["[^/]*" | acc])
  defp glob_source(["?" | rest], acc), do: glob_source(rest, ["[^/]" | acc])
  defp glob_source(["{" | rest], acc), do: glob_source(rest, ["(?:" | acc], :alt)

  defp glob_source(["[" | rest], acc) do
    {class, ["]" | rest]} = Enum.split_while(rest, &(&1 != "]"))
    glob_source(rest, ["[" <> Enum.join(class) <> "]" | acc])
  end

  defp glob_source([c | rest], acc), do: glob_source(rest, [Regex.escape(c) | acc])

  defp glob_source(["}" | rest], acc, :alt), do: glob_source(rest, [")" | acc])
  defp glob_source(["," | rest], acc, :alt), do: glob_source(rest, ["|" | acc], :alt)
  defp glob_source(["*" | rest], acc, :alt), do: glob_source(rest, ["[^/]*" | acc], :alt)
  defp glob_source([c | rest], acc, :alt), do: glob_source(rest, [Regex.escape(c) | acc], :alt)

  # A marker, or a comment a class reads as its marker (`marker:`, §11.7).
  def own_marker?(st, line), do: own_marker?(line) or alias_class(st, line) != nil
end
