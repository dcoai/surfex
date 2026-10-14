defmodule Mix.Tasks.Surfex.Test do
  @shortdoc "Run the tests that declare a spec unit, list tags included"

  @moduledoc """
  Runs a requirement's tests as surfex reads them (`Surfex.Select`, §11): every test whose
  `verifies:` declarations resolve to the unit, a list's members included.

      mix surfex.test cart-add                 # the tests declaring it
      mix surfex.test spec.md#carts --within   # and those of the units inside it
      mix surfex.test cart-add --list          # name them; run nothing
      mix surfex.test cart-add -- --trace      # what follows `--` goes to mix test
      mix surfex.test --deviations             # every deviation test, skips included
      mix surfex.test plat-3 --checks          # and the checks verifying it

  `mix test --only verifies:cart-add` selects a test tagged `["cart-add", "carts"]` by
  neither id: ExUnit compares a list tag as one string. This task selects by declaration
  and runs `mix test FILE:LINE …` in a child process, which ExUnit's location filter
  selects exactly, then exits with that run's status. The run records its evidence as any
  run does. Each unit is any reference a tag may use. A unit that is unknown, ambiguous,
  or that no test declares is an error before anything runs.

  `--deviations` runs every test that declares a deviation (`@tag deviation: "#119"`,
  `Surfex.Select.deviations/1`) instead of a unit's, each by `--only location:FILE:LINE`
  and its skip reason by `--include skip:REASON` (`Surfex.Select.deviation_args/1`), so
  the skip beside the tag doesn't keep it from running and no other test runs. Its
  evidence then says whether any passes: `mix surfex.status --evidence` fails a passing
  one as a stale deviation. It takes no unit. None to run, another test in their files
  skipped for a deviation test's reason, or a skip reason that isn't a literal, is an
  error before anything runs.

  A unit may also be verified by declared checks (`checks:`, §11.4). `--list` names them
  after the tests, and a run says which there are. `--checks` runs them too, after the
  tests, recording their evidence as `mix surfex.check` does (§17.1); the task fails if
  either the tests or a check fail. With `--checks`, a unit only checks verify is no
  error.
  """

  use Mix.Task

  alias Surfex.{Check, Evidence, Select}
  alias Surfex.Status.Config

  @impl Mix.Task
  def run(args) do
    {ours, passed} =
      case Enum.split_while(args, &(&1 != "--")) do
        {ours, ["--" | passed]} -> {ours, passed}
        {ours, []} -> {ours, []}
      end

    {opts, refs} =
      OptionParser.parse!(ours,
        strict: [
          within: :boolean,
          list: :boolean,
          config: :string,
          deviations: :boolean,
          checks: :boolean
        ]
      )

    deviations? = opts[:deviations] == true

    cond do
      deviations? and refs != [] ->
        Mix.raise("--deviations runs every deviation test: name no unit")

      not deviations? and refs == [] ->
        Mix.raise("name a spec unit: mix surfex.test UNIT… [--within] [--list], or --deviations")

      true ->
        :ok
    end

    root = File.cwd!()
    config = Config.read!(Path.join(root, opts[:config] || ".surfex.exs"))

    if config[:tests] == nil,
      do: Mix.raise(".surfex.exs names no tests: to scan, so no test declares anything")

    if Config.project_scanner?(config), do: Mix.Task.run("compile")

    scans = Config.scans(config, root)

    select = fn checks? ->
      Select.tests(scans, refs,
        within: opts[:within] || false,
        unit_refs: Config.unit_refs!(config),
        checks: checks?
      )
    end

    # The checks verifying the units, whatever the run takes (§11.4).
    checks =
      case if(deviations?, do: {:ok, []}, else: select.(true)) do
        {:ok, verifiers} -> Enum.filter(verifiers, &(&1.kind == :check))
        {:error, _} -> []
      end

    selected =
      cond do
        deviations? -> Select.deviations(scans)
        opts[:checks] || opts[:list] -> select.(true)
        true -> select.(false)
      end

    verifiers =
      case selected do
        {:ok, verifiers} ->
          verifiers

        {:error, message} ->
          hint = if checks == [], do: "", else: " (checks verify it: run them with --checks)"
          Mix.raise(message <> hint)
      end

    {_, tests} = Enum.split_with(verifiers, &(&1.kind == :check))

    # A deviation test is skipped beside its tag: included by its reason, it runs (§17).
    {selection, what} =
      if deviations?,
        do: {Select.deviation_args(tests), "a deviation"},
        else: {Select.args(tests), Enum.join(refs, ", ")}

    cond do
      opts[:list] ->
        for t <- tests, do: Mix.shell().info("#{t.id}  #{hd(Select.args([t]))}")
        for c <- checks, do: Mix.shell().info("check #{c.id}  #{c.check.run}")

      true ->
        status = if tests == [], do: 0, else: run_tests(tests, selection, passed, what, root)

        if checks != [] and opts[:checks] != true,
          do:
            Mix.shell().info(
              "checks verifying it too: #{Enum.map_join(checks, ", ", & &1.id)} (run them with --checks)"
            )

        failed = if opts[:checks], do: run_checks(checks, root), else: []

        cond do
          status != 0 -> exit({:shutdown, status})
          failed != [] -> Mix.raise("checks failed: #{Enum.join(failed, ", ")}")
          true -> :ok
        end
    end
  end

  defp run_tests(tests, selection, passed, what, root) do
    argv = selection ++ passed
    n = length(tests)

    Mix.shell().info(
      "running #{n} #{if n == 1, do: "test", else: "tests"} declaring #{what}: " <>
        Enum.join(["mix", "test" | argv], " ")
    )

    mix = System.find_executable("mix") || Mix.raise("no mix executable on the PATH")

    {_, status} =
      System.cmd(mix, ["test" | argv], cd: root, into: IO.stream(), stderr_to_stdout: true)

    status
  end

  # The checks' results recorded as `mix surfex.check` records them (§17.1); the ids of
  # those that failed.
  defp run_checks(checks, root) do
    records =
      Check.run(checks, root, fn command, root ->
        Mix.shell().info("running: #{command}")
        Check.shell(command, root)
      end)

    Evidence.append(Evidence.path(root), records)
    for r <- records, do: Mix.shell().info("check #{r.test}: #{r.result}")
    for %{result: :failed, test: id} <- records, do: id
  end
end
