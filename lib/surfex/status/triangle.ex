defmodule Surfex.Status.Triangle do
  @moduledoc false
  # §13.17: the triangle's mode, for the whole project or by spec file. `triangle:` is
  # `:report`, `:fail`, `[default: :report, fail: globs]` or `[default: :fail, report: globs]`:
  # a gap in a unit whose file matches one of the globs takes the listed mode, any other
  # gap the default. The globs read as `Path.wildcard/1` reads them, relative to the root.
  # One module holds the form, so `.surfex.exs` (Keys) and `Surfex.Status.derive/4` accept
  # the same values.

  alias Surfex.Scan.Markdown

  @type mode :: :report | :fail
  @type setting ::
          mode | [default: :report, fail: [String.t()]] | [default: :fail, report: [String.t()]]

  @doc false
  # The accepted forms, as a refusal names them.
  @spec form() :: String.t()
  def form,
    do:
      ":report, :fail, [default: :report, fail: [glob, …]] or [default: :fail, report: [glob, …]]"

  @doc false
  # The setting resolved to one of its forms, `default:` first, or `:error` for anything
  # else: another key, both lists, a list naming the default's own mode, or a glob that
  # isn't a string.
  @spec resolve(term) :: {:ok, setting} | :error
  def resolve(mode) when mode in [:report, :fail], do: {:ok, mode}

  def resolve(setting) when is_list(setting) and length(setting) == 2 do
    with true <- Keyword.keyword?(setting),
         {:ok, default} when default in [:report, :fail] <- Keyword.fetch(setting, :default),
         listed = other(default),
         {:ok, globs} <- Keyword.fetch(setting, listed),
         true <- is_list(globs) and Enum.all?(globs, &is_binary/1) do
      {:ok, [{:default, default}, {listed, globs}]}
    else
      _ -> :error
    end
  end

  def resolve(_), do: :error

  @doc false
  # The globs of a resolved setting: none for a whole-project mode.
  @spec globs(setting) :: [String.t()]
  def globs(mode) when is_atom(mode), do: []
  def globs([{:default, _}, {_, globs}]), do: globs

  @doc false
  # The mode of a gap in a unit of `file` (`nil` for a unit no longer scanned, which takes
  # the default).
  @spec mode(setting, String.t() | nil) :: mode
  def mode(mode, _file) when is_atom(mode), do: mode
  def mode([{:default, default}, _], nil), do: default

  def mode([{:default, default}, {listed, globs}], file),
    do: if(Enum.any?(globs, &Markdown.glob_match?(&1, file)), do: listed, else: default)

  defp other(:report), do: :fail
  defp other(:fail), do: :report
end
