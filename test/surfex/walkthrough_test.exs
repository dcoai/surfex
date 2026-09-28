defmodule Surfex.WalkthroughTest do
  @moduledoc """
  The relation log's acceptance walk-through, end to end, with the real tasks and real
  git: relate a spec section and a function; edit the function and see it dangle on the
  code side; confirm it; confirm the same relation on two branches and merge, and see the
  conflict; resolve it. Every step is read back from `mix surfex.status --format json`.
  """
  # The tasks read the working directory, which is global.
  use ExUnit.Case, async: false

  @moduletag :tmp_dir
  @project Path.expand("../fixtures/elixir_project", __DIR__)
  @section "spec.md#Totals"
  @function "MyApp.Cart.total/0"

  setup %{tmp_dir: root} do
    File.cp_r!(@project, root)
    File.write!(Path.join(root, "spec.md"), "# Totals\n\nA cart's total.\n")
    File.write!(Path.join(root, ".surfex.exs"), ~s([sources: ["spec.md"]]))
    git(root, ["init", "--quiet", "-b", "main"])
    git(root, ["config", "user.name", "Tester"])
    git(root, ["config", "user.email", "tester@example.com"])
    task(root, Mix.Tasks.Surfex.Log, ["--init"])
    commit(root, "base")
    %{root: root}
  end

  defp git(root, args) do
    {out, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    out
  end

  defp commit(root, message) do
    git(root, ["add", "-A"])
    git(root, ["commit", "--quiet", "-m", message])
  end

  defp task(root, module, args) do
    File.cd!(root, fn ->
      Mix.shell(Mix.Shell.Process)
      module.run(args)
    end)
  after
    Mix.shell(Mix.Shell.IO)
  end

  # The one relation's state, from the JSON report.
  # A passing status: if the task fails here, so does the test.
  defp status(root) do
    task(root, Mix.Tasks.Surfex.Status, ["--format", "json"])
    read_status()
  end

  defp read_status do
    json = drain() |> Enum.find(&String.starts_with?(&1, "{")) |> :json.decode()
    [relation] = json["relations"]
    relation
  end

  defp failing_status(root) do
    assert_raise Mix.Error, fn ->
      File.cd!(root, fn ->
        Mix.shell(Mix.Shell.Process)
        Mix.Tasks.Surfex.Status.run(["--format", "json"])
      end)
    end

    Mix.shell(Mix.Shell.IO)
    read_status()
  end

  defp drain(acc \\ []) do
    receive do
      {:mix_shell, :info, [text]} -> drain([text | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp edit_total(root, to) do
    path = Path.join(root, "lib/my_app/cart.ex")

    File.write!(
      path,
      Regex.replace(
        ~r/def total, do: helper\(\d\)/,
        File.read!(path),
        "def total, do: helper(#{to})"
      )
    )
  end

  test "relate → dangling → confirm → conflict across branches → resolve", %{root: root} do
    task(root, Mix.Tasks.Surfex.Relate, [@section, @function, "--type", "implements"])
    commit(root, "relate")
    assert %{"state" => "current"} = status(root)

    # An edit to the function dangles the relation, and says which side moved.
    edit_total(root, 1)
    commit(root, "edit")
    assert %{"state" => "dangling", "ends" => ends} = failing_status(root)

    assert %{"changed" => true, "location" => %{"file" => "lib/my_app/cart.ex"}} =
             Enum.find(ends, &(&1["kind"] == "code"))

    assert %{"changed" => false} = Enum.find(ends, &(&1["kind"] == "spec"))

    task(root, Mix.Tasks.Surfex.Confirm, [@function])
    commit(root, "confirm")
    assert %{"state" => "current"} = status(root)

    # Another edit, then both branches confirm it without seeing each other.
    edit_total(root, 2)
    commit(root, "edit again")
    git(root, ["checkout", "--quiet", "-b", "other"])
    task(root, Mix.Tasks.Surfex.Confirm, [@function, "--note", "checked on other"])
    commit(root, "confirm on other")
    git(root, ["checkout", "--quiet", "main"])
    task(root, Mix.Tasks.Surfex.Confirm, [@function, "--note", "checked on main"])
    commit(root, "confirm on main")
    git(root, ["merge", "--quiet", "--no-edit", "other"])

    assert %{"state" => "conflicted", "tips" => [tip, _]} = failing_status(root)

    task(root, Mix.Tasks.Surfex.Resolve, [
      @section,
      @function,
      "--type",
      "implements",
      "--pick",
      String.slice(tip, 0, 10)
    ])

    commit(root, "resolve")
    assert %{"state" => "current"} = status(root)

    # The whole story is in the log, and history reads it back.
    task(root, Mix.Tasks.Surfex.History, [@function])
    lines = drain()
    assert length(lines) == 5
    assert Enum.all?(lines, &String.contains?(&1, "by Tester <tester@example.com>"))
    assert Enum.any?(lines, &String.contains?(&1, "checked on other"))

    task(root, Mix.Tasks.Surfex.Log, ["--verify"])
    assert [text] = drain()
    assert text =~ "relation log verified: 5 entries"
  end
end
