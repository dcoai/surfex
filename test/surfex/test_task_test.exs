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

  @tag verifies: ["test-selection", "scan-records"]
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

  # #224: a deviation test is skipped beside its tag; --deviations runs it anyway, so its
  # evidence can say the deviation is fixed.
  @tag verifies: ["test-deviations", "test-selection", "scan-records"]
  test "--deviations runs exactly the deviation tests, skips included", %{tmp_dir: root} do
    assert_raise Mix.Error, "no test declares a deviation", fn ->
      task(root, ["--deviations"])
    end

    # Beside the deviation, a test skipped for another reason: it must stay skipped.
    deviant_source = fn other_reason ->
      """
      defmodule DeviantTest do
        use ExUnit.Case

        @tag verifies: "c", deviation: "#9", skip: "known deviation (#9): free over 50"
        test "deviant", do: assert(Selected.one() == 1)

        @tag skip: "#{other_reason}"
        test "parked", do: flunk("a test skipped for another reason ran")
      end
      """
    end

    deviant_file = Path.join(root, "test/deviant_test.exs")
    File.write!(deviant_file, deviant_source.("parked for now"))

    assert_raise Mix.Error, ~r/name no unit/, fn -> task(root, ["--deviations", "a"]) end

    task(root, ["--deviations", "--list"])
    assert infos() == ["DeviantTest: deviant  test/deviant_test.exs:5"]
    refute File.exists?(Path.join(root, "_build"))

    run = capture_io(fn -> task(root, ["--deviations", "--", "--seed", "0"]) end)
    assert run =~ "Result: 1 passed, 1 excluded"
    refute run =~ "another reason ran"

    assert infos() == [
             "running 1 test declaring a deviation: " <>
               "mix test test/deviant_test.exs --only location:test/deviant_test.exs:5 " <>
               "--include skip:known deviation (#9): free over 50 --seed 0"
           ]

    # Skipped for the deviation's own reason, the other test would run too: refused.
    File.write!(deviant_file, deviant_source.("known deviation (#9): free over 50"))

    assert_raise Mix.Error, ~r/DeviantTest: parked is skipped for the reason/, fn ->
      task(root, ["--deviations"])
    end
  end
end
