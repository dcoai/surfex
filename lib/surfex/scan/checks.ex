defmodule Surfex.Scan.Checks do
  @moduledoc """
  The check scanner: one `Surfex.Scan` record of kind `:check` per check `.surfex.exs`
  declares (`checks:`, §11.4). A **check** is a gate that can fail, a command such as a
  linter rule or a project's own verification task, and the claims it verifies:

      checks: [
        [id: "no-rescue", run: "mix credo --strict --only Credo.Check.Warning.Rescue",
         verifies: ["plat-3"], inputs: [".credo.exs", "lib/**/*.ex"]]
      ]

    * **id** — the check's `id`: letters, digits and `.` `_` `-`, starting with a letter or
      digit, so it is never a test's id
    * **hash** — its version: over its declaration (`run`, `verifies`, `inputs`) and the
      content of every file its `inputs` globs match. Changing the rule, what it verifies
      or what it inspects is a new version; any other file is not.
    * **declares** — `{:verifies, ref}` per `verifies` entry, resolved as a test's
      declarations are (`Surfex.Scan.resolve/2`)
    * **check** — `%{run, declaration, inputs}`: the command, the declaration's version
      alone, and each input file's version. Evidence of a run (`mix surfex.check`) is
      recorded at the declaration's version against the inputs' versions, as a test's run
      is against its code's (§17.1).
    * **location** — `.surfex.exs`, with no lines: the config is evaluated data.

  A function of the config and the inputs' content.
  """

  alias Surfex.Scan

  @id ~r/^[A-Za-z0-9][A-Za-z0-9._-]*$/

  @doc """
  The project's checks (`checks:` in `config`), validated: each a keyword list with `id`
  (unique), `run` (a non-empty command), `verifies` (a reference or a non-empty list of
  them) and optionally `inputs` (globs). `[]` without the key. Raises `ArgumentError`
  naming what is wrong.
  """
  @spec declared!(keyword) :: [
          %{id: String.t(), run: String.t(), verifies: [String.t()], inputs: [String.t()]}
        ]
  def declared!(config) do
    checks =
      case Keyword.get(config, :checks, []) do
        list when is_list(list) -> Enum.map(list, &check!/1)
        other -> raise ArgumentError, "checks: must be a list of checks, got #{inspect(other)}"
      end

    case checks |> Enum.frequencies_by(& &1.id) |> Enum.find(fn {_, n} -> n > 1 end) do
      nil -> checks
      {id, _} -> raise ArgumentError, "checks: the id #{inspect(id)} is declared twice"
    end
  end

  defp check!(check) do
    unless is_list(check) and Keyword.keyword?(check),
      do: raise(ArgumentError, "checks: each check is a keyword list, got #{inspect(check)}")

    case Keyword.keys(check) -- [:id, :run, :verifies, :inputs] do
      [] -> :ok
      unknown -> raise ArgumentError, "checks: unknown keys #{inspect(unknown)}"
    end

    id = Keyword.get(check, :id)

    unless is_binary(id) and Regex.match?(@id, id),
      do:
        raise(
          ArgumentError,
          "checks: id must be letters, digits and . _ -, starting with a letter or digit, got #{inspect(id)}"
        )

    run = Keyword.get(check, :run)

    unless is_binary(run) and String.trim(run) != "",
      do: raise(ArgumentError, "checks: #{id} needs run: a command, got #{inspect(run)}")

    verifies = check |> Keyword.get(:verifies) |> List.wrap()

    unless verifies != [] and Enum.all?(verifies, &(is_binary(&1) and &1 != "")),
      do:
        raise(
          ArgumentError,
          "checks: #{id} needs verifies: a spec unit or a list of them, got #{inspect(check[:verifies])}"
        )

    inputs = Keyword.get(check, :inputs, [])

    unless is_list(inputs) and Enum.all?(inputs, &is_binary/1),
      do:
        raise(
          ArgumentError,
          "checks: #{id} inputs: must be a list of globs, got #{inspect(inputs)}"
        )

    %{id: id, run: run, verifies: verifies, inputs: inputs}
  end

  @doc """
  One record per declared check (`declared!/1`), sorted by id, its inputs read under
  `root`. An input glob that matches no file raises: a misspelt input would leave the
  check's version blind to what it inspects.
  """
  @spec records(keyword, String.t()) :: [Scan.t()]
  def records(config, root) do
    for check <- declared!(config) do
      inputs = inputs!(check, root)
      declaration = declaration(check)

      %Scan{
        kind: :check,
        id: check.id,
        hash: version(declaration, inputs),
        location: %{file: ".surfex.exs", lines: nil},
        declares: for(ref <- Enum.uniq(check.verifies), do: {:verifies, ref}),
        check: %{run: check.run, declaration: declaration, inputs: inputs}
      }
    end
    |> Enum.sort_by(& &1.id)
  end

  @doc """
  A check's version from its declaration's version and its inputs' versions (a map of
  file to version): what its record's `hash` is, and what a run's evidence is compared
  with (§17.1).
  """
  @spec version(String.t(), %{String.t() => String.t()}) :: String.t()
  def version(declaration, inputs), do: hash([declaration, Enum.sort(inputs)])

  # The declaration's own version: its command, what it verifies, and its input globs.
  defp declaration(check),
    do: hash([check.run, Enum.sort(Enum.uniq(check.verifies)), Enum.sort(check.inputs)])

  defp inputs!(check, root) do
    for glob <- check.inputs, reduce: %{} do
      acc ->
        files = root |> Path.join(glob) |> Path.wildcard() |> Enum.filter(&File.regular?/1)

        if files == [],
          do:
            raise(
              ArgumentError,
              "checks: #{check.id} input #{inspect(glob)} matches no file under #{root}"
            )

        Enum.reduce(files, acc, fn file, acc ->
          Map.put(acc, Path.relative_to(file, root), file |> File.read!() |> hash())
        end)
    end
  end

  defp hash(term) do
    :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic]))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 8)
  end
end
