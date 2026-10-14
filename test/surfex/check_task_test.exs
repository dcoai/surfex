defmodule Surfex.CheckTaskTest do
  # #207 (B.3), #245: the tasks that run checks read the working directory, which is
  # global, and run real commands.
  use ExUnit.Case, async: false
  @moduletag :tmp_dir
  @moduletag verifies: "check-run"

  setup %{tmp_dir: root} do
    files = %{
      "spec.md" => "# App\n\n```test:plat-3\nno rescue\n```\n\n```test:plat-4\nsomething\n```\n",
      "rules.txt" => "deny rescue\n",
      "lib/app.ex" => "defmodule App do\n  def f, do: 1\nend\n",
      "test/app_test.exs" =>
        "defmodule AppTest do\n  use ExUnit.Case\n  @tag verifies: \"plat-4\"\n  test \"f\", do: assert(App.f() == 1)\nend\n",
      ".surfex.exs" => """
      [sources: ["spec.md"], tests: ["test/*_test.exs"],
       checks: [[id: "passes", run: "test -f rules.txt", verifies: "plat-3", inputs: ["rules.txt"]],
                [id: "fails", run: "test -f nothing.txt", verifies: "plat-3"]]]
      """
    }

    for {path, text} <- files do
      File.mkdir_p!(Path.dirname(Path.join(root, path)))
      File.write!(Path.join(root, path), text)
    end

    :ok
  end

  # Each task is called by name, so the test's calls reach what it runs (§11).
  defp check(root, args), do: in_project(root, fn -> Mix.Tasks.Surfex.Check.run(args) end)
  defp test_task(root, args), do: in_project(root, fn -> Mix.Tasks.Surfex.Test.run(args) end)

  defp in_project(root, run) do
    File.cd!(root, fn ->
      Mix.shell(Mix.Shell.Process)
      run.()
    end)
  after
    Mix.shell(Mix.Shell.IO)
  end

  defp infos(acc \\ []) do
    receive do
      {:mix_shell, :info, [text]} -> infos([text | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @tag verifies: ["check-run", "checks"]
  test "mix surfex.check records evidence and fails when a check failed; --list runs nothing",
       %{tmp_dir: root} do
    evidence = Path.join(root, "evidence.jsonl")
    check(root, ["passes", "--evidence", evidence])
    assert [%{test: "passes", result: :passed}] = Surfex.Evidence.load(evidence)

    assert_raise Mix.Error, ~r/checks failed: fails/, fn ->
      check(root, ["--evidence", evidence])
    end

    assert [%{result: :failed, test: "fails"}, %{result: :passed}, %{result: :passed}] =
             evidence |> Surfex.Evidence.load() |> Enum.sort_by(&{&1.result, &1.at})

    check(root, ["--list", "--evidence", evidence])
    assert length(Surfex.Evidence.load(evidence)) == 3

    assert_raise Mix.Error, ~r/no check has the id nope/, fn -> check(root, ["nope"]) end
  end

  @tag verifies: ["check-run", "checks"]
  test "mix surfex.test lists the checks verifying a unit, and runs them with --checks",
       %{tmp_dir: root} do
    infos()

    test_task(root, ["plat-3", "--list"])
    assert infos() == ["check fails  test -f nothing.txt", "check passes  test -f rules.txt"]

    # Only checks verify it: an error without --checks, saying so.
    assert_raise Mix.Error, ~r/no test declares spec.md#plat-3 \(checks verify it/, fn ->
      test_task(root, ["plat-3"])
    end

    assert_raise Mix.Error, ~r/checks failed: fails/, fn ->
      test_task(root, ["plat-3", "--checks"])
    end

    assert [_, _] =
             root
             |> Surfex.Evidence.path()
             |> Surfex.Evidence.load()
             |> Enum.filter(&(&1.test in ["fails", "passes"]))
  end
end
