defmodule Mix.Tasks.Surfex.Test do
  @shortdoc "Run the tests that declare a spec unit, list tags included"

  @moduledoc """
  Runs a requirement's tests as surfex reads them (`Surfex.Select`, §11): every test whose
  `verifies:` declarations resolve to the unit, a list's members included.

      mix surfex.test cart-add                 # the tests declaring it
      mix surfex.test spec.md#carts --within   # and those of the units inside it
      mix surfex.test cart-add --list          # name them; run nothing
      mix surfex.test cart-add -- --trace      # what follows `--` goes to mix test

  `mix test --only verifies:cart-add` selects a test tagged `["cart-add", "carts"]` by
  neither id: ExUnit compares a list tag as one string. This task selects by declaration
  and runs `mix test FILE:LINE …` in a child process, which ExUnit's location filter
  selects exactly, then exits with that run's status. The run records its evidence as any
  run does. Each unit is any reference a tag may use. A unit that is unknown, ambiguous,
  or that no test declares is an error before anything runs.
  """

  use Mix.Task

  alias Surfex.Select
  alias Surfex.Status.Config

  @impl Mix.Task
  def run(args) do
    {ours, passed} =
      case Enum.split_while(args, &(&1 != "--")) do
        {ours, ["--" | passed]} -> {ours, passed}
        {ours, []} -> {ours, []}
      end

    {opts, refs} =
      OptionParser.parse!(ours, strict: [within: :boolean, list: :boolean, config: :string])

    if refs == [], do: Mix.raise("name a spec unit: mix surfex.test UNIT… [--within] [--list]")

    root = File.cwd!()
    config = Config.read!(Path.join(root, opts[:config] || ".surfex.exs"))

    if config[:tests] == nil,
      do: Mix.raise(".surfex.exs names no tests: to scan, so no test declares anything")

    if Keyword.get(config, :scanner, :elixir) != :elixir, do: Mix.Task.run("compile")

    tests =
      case Select.tests(Config.scans(config, root), refs, within: opts[:within] || false) do
        {:ok, tests} -> tests
        {:error, message} -> Mix.raise(message)
      end

    if opts[:list] do
      for t <- tests, do: Mix.shell().info("#{t.id}  #{hd(Select.args([t]))}")
    else
      argv = Select.args(tests) ++ passed
      n = length(tests)

      Mix.shell().info(
        "running #{n} #{if n == 1, do: "test", else: "tests"} declaring #{Enum.join(refs, ", ")}: " <>
          Enum.join(["mix", "test" | argv], " ")
      )

      mix = System.find_executable("mix") || Mix.raise("no mix executable on the PATH")

      case System.cmd(mix, ["test" | argv], cd: root, into: IO.stream(), stderr_to_stdout: true) do
        {_, 0} -> :ok
        {_, status} -> exit({:shutdown, status})
      end
    end
  end
end
