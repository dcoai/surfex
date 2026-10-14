defmodule Mix.Tasks.Surfex.Check do
  @shortdoc "Run the declared checks and record their results as evidence"

  @moduledoc """
  Runs the checks `.surfex.exs` declares (`checks:`, §11.4) and records each result as
  evidence (§17.1), in the file the test formatter writes (`Surfex.Evidence.path/1`):

      mix surfex.check                 # every check
      mix surfex.check no-rescue       # these checks
      mix surfex.check --list          # name them; run nothing

  Each check's command runs in the project's root with the system's shell. Exit status 0
  is passed, anything else failed, recorded at the check's declaration's version against
  its inputs' versions. A check discriminates as a test does: once its declaration has
  failed against one set of inputs and passed against another, `mix surfex.confirm
  --evidence` confirms its `verifies` relations. Deliberately breaking an input to show it
  fails is that discrimination run.

  The task exits non-zero when any check failed, so it is also the gate. An unknown id, or
  a project with no checks, is an error before anything runs. `--evidence PATH` records
  to another file (a CI job's artifact).
  """

  use Mix.Task

  alias Surfex.{Check, Evidence, Scan}
  alias Surfex.Status.Config

  @impl Mix.Task
  def run(args) do
    {opts, ids} =
      OptionParser.parse!(args, strict: [list: :boolean, config: :string, evidence: :string])

    root = File.cwd!()
    config = Config.read!(Path.join(root, opts[:config] || ".surfex.exs"))

    checks =
      case Check.select(Scan.Checks.records(config, root), ids) do
        {:ok, checks} -> checks
        {:error, message} -> Mix.raise(message)
      end

    if opts[:list] do
      for c <- checks, do: Mix.shell().info("#{c.id}  #{c.check.run}")
    else
      records =
        Check.run(checks, root, fn command, root ->
          Mix.shell().info("running: #{command}")
          Check.shell(command, root)
        end)

      for r <- records, do: Mix.shell().info("check #{r.test}: #{r.result}")

      Evidence.append(opts[:evidence] || Evidence.path(root), records)

      case for(%{result: :failed, test: id} <- records, do: id) do
        [] -> :ok
        failed -> Mix.raise("checks failed: #{Enum.join(failed, ", ")}")
      end
    end
  end
end
