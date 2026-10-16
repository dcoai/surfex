defmodule Surfex.Scan.Errors do
  @moduledoc """
  The scan errors of a spec and its tests, reported together (§11.11): a line that can't be
  read as written, each `%{file, line, message}`. The scan reads past every one, so a run
  names them all; raised once, when the scan is done, this prints them sorted by file and
  line, `file:line: message` each, and a mix task exits with no stack trace.
  """

  defexception [:errors, mix: true]

  @typedoc "One scan error: the file and line it is at, and what is wrong."
  @type error :: %{file: String.t(), line: non_neg_integer, message: String.t()}

  @type t :: %__MODULE__{errors: [error], mix: true}

  @impl true
  def message(%__MODULE__{errors: errors}) do
    n = length(errors)
    noun = if n == 1, do: "scan error", else: "scan errors"
    "#{n} #{noun}: the spec and tests can't be read as written\n" <> lines(errors)
  end

  @doc "Errors in file and line order; errors at one line keep the order they were found in."
  @spec sorted([error]) :: [error]
  def sorted(errors), do: Enum.sort_by(errors, &{&1.file, &1.line})

  @doc "Each error as `file:line: message`, one per line, sorted."
  @spec lines([error]) :: String.t()
  def lines(errors), do: errors |> sorted() |> Enum.map_join("\n", &line/1)

  defp line(%{file: file, line: line, message: message}), do: "#{file}:#{line}: #{message}"
end
