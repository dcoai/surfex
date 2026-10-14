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
