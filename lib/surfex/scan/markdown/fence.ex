defmodule Surfex.Scan.Markdown.Fence do
  @moduledoc false
  # Fenced code blocks by CommonMark's rule, one line at a time.
  #
  # A fence opens on three or more backticks or tildes, indented at most three spaces; a
  # backtick fence whose info string holds a backtick is not a fence. It closes only on a
  # line of the same character, at least as long, with nothing after it but whitespace.
  # One that never closes runs to the end of the text.

  @open ~r/^ {0,3}(`{3,}|~{3,})(.*)$/
  @close ~r/^ {0,3}(`{3,}|~{3,})[ \t]*$/

  @typedoc "Outside any fence (`nil`), or inside one opened by `{char, length}`."
  @type state :: nil | {String.t(), pos_integer}

  @doc """
  Where `line` leaves the reader, and whether the line is prose: `{prose?, state}`.
  A fence's own opening and closing lines are not prose, nor is anything between them.
  """
  @spec step(String.t(), state) :: {boolean, state}
  def step(line, nil) do
    case Regex.run(@open, line, capture: :all_but_first) do
      [marks, info] -> if opens?(marks, info), do: {false, open(marks)}, else: {true, nil}
      nil -> {true, nil}
    end
  end

  def step(line, {char, length} = fence) do
    case Regex.run(@close, line, capture: :all_but_first) do
      [marks] -> if closes?(marks, char, length), do: {false, nil}, else: {false, fence}
      nil -> {false, fence}
    end
  end

  @doc "The info string of a line that opens a fence (trimmed), or `nil` for any other line."
  @spec info(String.t()) :: String.t() | nil
  def info(line) do
    case Regex.run(@open, line, capture: :all_but_first) do
      [marks, info] -> if opens?(marks, info), do: String.trim(info)
      nil -> nil
    end
  end

  defp opens?("`" <> _, info), do: not String.contains?(info, "`")
  defp opens?(_tildes, _info), do: true

  defp open(marks), do: {String.first(marks), String.length(marks)}

  defp closes?(marks, char, length),
    do: String.first(marks) == char and String.length(marks) >= length
end
