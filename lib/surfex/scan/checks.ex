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

  `run` is a command string, run through the system's shell, or an argv, run with no
  shell (`Surfex.Check.run/3`). A function of the config and the inputs' content.
  """

  alias Surfex.Scan

  @doc """
  One record per declared check, sorted by id, its inputs read under `root`: the checks
  as `Surfex.Status.Config.checks!/1` validates `checks:` (§13.14). An input glob that
  matches no file raises: a misspelt input would leave the check's version blind to what
  it inspects.
  """
  @spec records([Surfex.Status.Config.check()], String.t()) :: [Scan.t()]
  def records(checks, root) do
    for check <- checks do
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
