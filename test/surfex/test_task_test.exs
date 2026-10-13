defmodule Surfex.TestTaskTest do
  # The task reads the working directory, which is global, and runs a real `mix test`.
  use ExUnit.Case, async: false
  @moduletag :tmp_dir
  @moduletag verifies: "test-selection"

  import ExUnit.CaptureIO

  # A project of its own: one test tagged with a list, which `--only` can't select by
  # either id, and one failing test that must not run.
  setup %{tmp_dir: root} do
    files = %{
      "mix.exs" => """
      defmodule Selected.MixProject do
        use Mix.Project
        def project, do: [app: :selected, version: "0.1.0"]
      end
      """,
      "lib/selected.ex" => "defmodule Selected do\n  def one, do: 1\nend\n",
      "spec.md" =>
        "# Selected\n\n```test a\none\n```\n\n```test b\ntwo\n```\n\n```test c\nthree\n```\n",
      ".surfex.exs" => ~s([sources: ["spec.md"], tests: ["test/**/*_test.exs"]]),
      "test/test_helper.exs" => "ExUnit.start()\n",
      "test/selected_test.exs" => """
      defmodule SelectedTest do
        use ExUnit.Case

        @tag verifies: ["a", "b"]
        test "both", do: assert(Selected.one() == 1)

        @tag verifies: "c"
        test "other", do: flunk("not selected")
      end
      """
    }

    for {path, text} <- files do
      File.mkdir_p!(Path.dirname(Path.join(root, path)))
      File.write!(Path.join(root, path), text)
    end

    :ok
  end

  defp task(root, args) do
    File.cd!(root, fn ->
      Mix.shell(Mix.Shell.Process)
      Mix.Tasks.Surfex.Test.run(args)
    end)
  after
    Mix.shell(Mix.Shell.IO)
  end

  defp infos, do: infos([])

  defp infos(acc) do
    receive do
      {:mix_shell, :info, [text]} -> infos([text | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "--list names the selected tests and runs nothing", %{tmp_dir: root} do
    task(root, ["a", "--list"])
    assert infos() == ["SelectedTest: both  test/selected_test.exs:5"]
    refute File.exists?(Path.join(root, "_build"))
  end

  test "it runs exactly the declaring tests by location, where --only selects none", %{
    tmp_dir: root
  } do
    {only, _} =
      System.cmd("mix", ["test", "--only", "verifies:a"], cd: root, stderr_to_stdout: true)

    assert only =~ "All tests have been excluded."

    run = capture_io(fn -> task(root, ["a", "--", "--seed", "0"]) end)
    assert run =~ ~s(Including tags: [location: {"test/selected_test.exs", 5}])
    assert run =~ "Result: 1 passed, 1 excluded"
    assert infos() == ["running 1 test declaring a: mix test test/selected_test.exs:5 --seed 0"]
  end

  test "a failing selection exits with the run's status", %{tmp_dir: root} do
    capture_io(fn ->
      assert catch_exit(task(root, ["c"])) == {:shutdown, 2}
    end)
  end

  test "a unit no test declares is an error, and nothing runs", %{tmp_dir: root} do
    File.write!(Path.join(root, "spec.md"), "# Selected\n\n```test d\nfour\n```\n", [:append])

    assert_raise Mix.Error, "no test declares spec.md#d", fn -> task(root, ["d"]) end
    assert_raise Mix.Error, ~r/name a spec unit/, fn -> task(root, []) end
    refute File.exists?(Path.join(root, "_build"))
  end
end
