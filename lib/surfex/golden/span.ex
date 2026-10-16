defmodule Surfex.Golden.Span do
  @moduledoc false
  # The GFM notation of a golden's table cells (spec §2.2, #199), in one place: what
  # `Surfex.Golden` renders every backticked cell with, and what surfex's own goldens build
  # their composite `{:raw, …}` cells from. Internal: `Surfex.Golden`'s documented surface is
  # library API (§23), and the proposal that brought this changed no API.
  #
  # GFM splits a table row on every `|` not escaped as `\|` BEFORE it reads a code span, so
  # a pipe splits a cell even inside backticks. A span then closes at the first backtick run
  # as long as its opener, and one space is stripped from each side of content that starts
  # and ends with a space and is not all spaces.
  #
  # Both sides live here: the writer (`code/1`, `text/1`) and the one reader of a GFM table
  # row (`cells/1`, `inline/1`, §11.15) that a marked table, the gate, citations and the
  # golden tests read cells with, so what surfex writes is what it reads.

  @doc """
  `text` as a code span that reads back as `text` inside a table cell: each `|` escaped as
  `\\|`; a delimiter one backtick longer than the longest backtick run in `text`; one space
  of padding each side when `text` starts or ends with a backtick (it would merge with the
  delimiter), or starts and ends with a space without being all spaces (GFM would strip it).
  """
  @spec code(iodata) :: iodata
  def code(text) do
    text = IO.iodata_to_binary(text)
    fence = String.duplicate("`", longest_backtick_run(text) + 1)
    pad = if pad?(text), do: " ", else: ""
    [fence, pad, String.replace(text, "|", "\\|"), pad, fence]
  end

  @doc "Free `text` for a table cell, each `|` escaped as `\\|` so it stays one cell."
  @spec text(iodata) :: iodata
  def text(text), do: text |> IO.iodata_to_binary() |> String.replace("|", "\\|")

  @typedoc "A piece of a cell's inline text: a code span's content, or raw text between spans."
  @type segment :: {:code, String.t()} | {:text, String.t()}

  @doc """
  A table row's cells as GFM reads them: the row split on every `|` not preceded by a
  backslash, code spans or not, the outer pipes dropped, each `\\|` made `|` and each cell
  trimmed. A row without outer pipes splits the same way.
  """
  @spec cells(String.t()) :: [String.t()]
  def cells(row) do
    parts = Regex.split(~r/(?<!\\)\|/, String.trim(row))
    parts = if hd(parts) == "", do: tl(parts), else: parts
    parts = if parts != [] and List.last(parts) == "", do: Enum.drop(parts, -1), else: parts
    Enum.map(parts, &(&1 |> String.replace("\\|", "|") |> String.trim()))
  end

  @doc """
  A cell's inline text as CommonMark reads its code spans, in order: a run of N backticks
  opens a span that closes at the next run of exactly N; inside it nothing is an escape, and
  one space is stripped from each side of content that starts and ends with a space and is
  not all spaces. A run with no closer is literal text, and so is a backtick escaped as
  `` \\` `` outside a span. Text between spans is raw: its backslash escapes are left for
  the reader of that text.
  """
  @spec inline(String.t()) :: [segment]
  def inline(cell), do: cell |> spans("", []) |> Enum.reverse()

  defp spans("", "", acc), do: acc
  defp spans("", text, acc), do: [{:text, text} | acc]

  defp spans(<<"\\", c, rest::binary>>, text, acc)
       when c in ~c"!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~",
       do: spans(rest, <<text::binary, "\\", c>>, acc)

  defp spans("`" <> _ = cell, text, acc) do
    [run] = Regex.run(~r/\A`+/, cell)
    n = byte_size(run)
    rest = binary_part(cell, n, byte_size(cell) - n)

    closer =
      ~r/`+/
      |> Regex.scan(rest, return: :index)
      |> Enum.map(&hd/1)
      |> Enum.find(fn {_at, len} -> len == n end)

    case closer do
      {at, ^n} ->
        acc = if text == "", do: acc, else: [{:text, text} | acc]
        after_closer = binary_part(rest, at + n, byte_size(rest) - at - n)
        spans(after_closer, "", [{:code, unpad(binary_part(rest, 0, at))} | acc])

      nil ->
        spans(rest, text <> run, acc)
    end
  end

  defp spans(<<c::utf8, rest::binary>>, text, acc),
    do: spans(rest, <<text::binary, c::utf8>>, acc)

  defp unpad(" " <> _ = inner) do
    if String.ends_with?(inner, " ") and String.trim(inner, " ") != "",
      do: binary_part(inner, 1, byte_size(inner) - 2),
      else: inner
  end

  defp unpad(inner), do: inner

  defp longest_backtick_run(text) do
    ~r/`+/
    |> Regex.scan(text)
    |> Enum.map(fn [run] -> byte_size(run) end)
    |> Enum.max(fn -> 0 end)
  end

  defp pad?(text) do
    String.starts_with?(text, "`") or String.ends_with?(text, "`") or
      (String.starts_with?(text, " ") and String.ends_with?(text, " ") and
         String.trim(text, " ") != "")
  end
end
