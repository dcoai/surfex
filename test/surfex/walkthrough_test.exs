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
    {json, :ok, _} =
      drain() |> Enum.find(&String.starts_with?(&1, "{")) |> :json.decode(:ok, %{null: nil})

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

  # #36: the spec is written first, the relation planned, and the code follows.
  @tag verifies: "planned-state"
  test "plan → planned → write the code → dangling → confirm", %{root: root} do
    planned = "MyApp.Cart.discount/1"
    task(root, Mix.Tasks.Surfex.Relate, ["--planned", @section, planned, "--type", "implements"])
    assert Enum.any?(drain(), &(&1 =~ "code #{planned}@planned"))
    commit(root, "plan")

    # Planned passes the everyday check, and fails the everything-built one.
    assert %{"state" => "planned", "ends" => ends} = status(root)
    assert %{"planned" => true, "recorded" => nil} = Enum.find(ends, &(&1["id"] == planned))

    assert_raise Mix.Error, fn ->
      task(root, Mix.Tasks.Surfex.Status, ["--no-planned"])
    end

    drain()

    # The code is written: the relation dangles on it until someone confirms it.
    path = Path.join(root, "lib/my_app/cart.ex")

    File.write!(
      path,
      String.replace(
        File.read!(path),
        "  def total,",
        "  def discount(cart), do: cart\n\n  def total,"
      )
    )

    commit(root, "write discount/1")
    assert %{"state" => "dangling", "ends" => ends} = failing_status(root)
    assert %{"changed" => true, "planned" => false} = Enum.find(ends, &(&1["id"] == planned))

    task(root, Mix.Tasks.Surfex.Confirm, [planned])
    commit(root, "confirm")
    assert %{"state" => "current"} = status(root)
    task(root, Mix.Tasks.Surfex.Status, ["--no-planned"])
  end

  test "a planned id that couldn't be the project's is refused", %{root: root} do
    for id <- ["MyAp.Cart.discount/1", "other.md#Totals"] do
      error =
        assert_raise Mix.Error, fn ->
          task(root, Mix.Tasks.Surfex.Relate, ["--planned", @function, id, "--type", "implements"])
        end

      assert error.message =~ "doesn't look like"
    end

    # --planned is relate's alone.
    assert_raise OptionParser.ParseError, fn ->
      task(root, Mix.Tasks.Surfex.Confirm, ["--planned", @function])
    end
  end

  # #38: the whole test-first flow, from a test hint to a closed triangle.
  test "hint → tagged test → planned code → code → suggest: the triangle closes", %{root: root} do
    File.write!(Path.join(root, "spec.md"), """
    # Totals {#totals}

    A cart's discount is taken off its total.

    ```test discount-test
    discounting an empty cart gives an empty cart
    ```
    """)

    File.write!(
      Path.join(root, ".surfex.exs"),
      ~s([sources: ["spec.md"], tests: ["test/*_test.exs"], require: [test_hint: [:verifies]]])
    )

    File.mkdir_p!(Path.join(root, "test"))

    File.write!(
      Path.join(root, "test/placeholder_test.exs"),
      "defmodule PlaceholderTest do\nend\n"
    )

    commit(root, "spec with a hint")

    # The hint needs a test: unmet.
    assert %{"unmet" => [%{"id" => "spec.md#discount-test"}]} = failing_json(root)

    # The test, written from the hint, before the code; and the relation, planned.
    File.write!(Path.join(root, "test/cart_test.exs"), """
    defmodule MyApp.CartTest do
      use ExUnit.Case
      alias MyApp.Cart

      @tag verifies: "discount-test"
      test "an empty cart stays empty" do
        assert Cart.discount([]) == []
      end
    end
    """)

    task(root, Mix.Tasks.Surfex.Relate, [
      "--planned",
      "spec.md#totals",
      "MyApp.Cart.discount/1",
      "--type",
      "implements"
    ])

    task(root, Mix.Tasks.Surfex.Suggest, ["--accept"])
    commit(root, "test first")

    # Met, and the triangle shows the code is missing: the test calls what isn't there.
    json = passing_json(root)
    assert json["unmet"] == []

    assert [
             %{"gap" => "test_misses_code"},
             %{"gap" => "code_untested", "code" => "MyApp.Cart.discount/1"}
           ] =
             json["triangle"]

    # The code: the planned relation dangles until confirmed, and suggest adds tests.
    path = Path.join(root, "lib/my_app/cart.ex")

    File.write!(
      path,
      String.replace(
        File.read!(path),
        "  def total,",
        "  def discount(cart), do: cart\n\n  def total,"
      )
    )

    task(root, Mix.Tasks.Surfex.Suggest, ["--accept"])
    task(root, Mix.Tasks.Surfex.Confirm, ["MyApp.Cart.discount/1"])
    commit(root, "code")

    json = passing_json(root)
    assert json["triangle"] == []
    assert Enum.all?(json["relations"], &(&1["state"] == "current"))

    assert Enum.sort(Enum.map(json["relations"], & &1["type"])) ==
             ["implements", "refines", "tests", "verifies"]
  end

  defp passing_json(root) do
    task(root, Mix.Tasks.Surfex.Status, ["--format", "json"])
    decode_report()
  end

  defp failing_json(root) do
    assert_raise Mix.Error, fn -> task(root, Mix.Tasks.Surfex.Status, ["--format", "json"]) end
    decode_report()
  end

  defp decode_report do
    {json, :ok, _} =
      drain() |> Enum.find(&String.starts_with?(&1, "{")) |> :json.decode(:ok, %{null: nil})

    json
  end

  # #54: from a hint to current relations, with no confirmation by hand. The evidence is
  # recorded by the real formatter, fed the events ExUnit would send.
  test "hint → red test → code → green → confirm --evidence: current, no human confirm",
       %{root: root} do
    File.write!(Path.join(root, "spec.md"), """
    # Totals {#totals}

    A cart's discount is taken off its total.

    ```test discount-test
    discounting an empty cart gives an empty cart
    ```
    """)

    File.write!(
      Path.join(root, ".surfex.exs"),
      ~s([sources: ["spec.md"], tests: ["test/*_test.exs"]])
    )

    File.mkdir_p!(Path.join(root, "test"))

    File.write!(Path.join(root, "test/cart_test.exs"), """
    defmodule MyApp.CartTest do
      use ExUnit.Case

      @tag verifies: "discount-test"
      test "an empty cart stays empty" do
        assert MyApp.Cart.discount([]) == []
      end
    end
    """)

    task(root, Mix.Tasks.Surfex.Relate, [
      "--planned",
      "spec.md#totals",
      "MyApp.Cart.discount/1",
      "--type",
      "implements"
    ])

    task(root, Mix.Tasks.Surfex.Suggest, ["--accept"])
    commit(root, "spec, hint, test first")

    # Red: the test fails, since the code doesn't exist yet.
    run_test(root, {:failed, []})

    path = Path.join(root, "lib/my_app/cart.ex")

    File.write!(
      path,
      String.replace(
        File.read!(path),
        "  def total,",
        "  def discount(cart), do: cart\n\n  def total,"
      )
    )

    task(root, Mix.Tasks.Surfex.Suggest, ["--accept"])

    # The planned relation dangles now the code exists; green, and evidence confirms it.
    assert %{"relations" => relations} = failing_json(root)
    assert Enum.any?(relations, &(&1["type"] == "implements" and &1["state"] == "dangling"))

    run_test(root, nil)
    task(root, Mix.Tasks.Surfex.Confirm, ["--evidence"])
    lines = drain()

    assert Enum.any?(
             lines,
             &(&1 =~ "recorded relate implements" and &1 =~ "confirmed by evidence")
           )

    commit(root, "code, green, confirmed by evidence")

    json = passing_json(root)
    assert Enum.all?(json["relations"], &(&1["state"] == "current"))
    assert json["triangle"] == []

    # What CI runs: the claims checked against the last run, and nothing recorded.
    task(root, Mix.Tasks.Surfex.Status, ["--verify", "--evidence"])
    assert drain() |> Enum.join() =~ "relation status: ok"

    # A run in which the test fails contradicts the claim, and the check fails.
    run_test(root, {:failed, []})
    assert_raise Mix.Error, fn -> task(root, Mix.Tasks.Surfex.Status, ["--evidence"]) end
    assert drain() |> Enum.join() =~ "Unproven"
    run_test(root, nil)

    # No entry was a named confirmation: the log shows evidence, not a person, for the code.
    task(root, Mix.Tasks.Surfex.History, ["MyApp.Cart.discount/1"])
    assert Enum.any?(drain(), &(&1 =~ "confirmed by evidence"))
  end

  # One run of the suite, as ExUnit reports it to the formatter.
  defp run_test(root, state) do
    {:ok, pid} = GenServer.start_link(Surfex.ExUnitFormatter, surfex_root: root)
    GenServer.cast(pid, {:suite_started, []})
    file = Path.join(root, "test/cart_test.exs")

    test = %ExUnit.Test{
      name: :t,
      module: MyApp.CartTest,
      state: state,
      tags: %{file: file, line: 5}
    }

    GenServer.cast(pid, {:test_finished, test})
    GenServer.cast(pid, {:suite_finished, %{}})
    GenServer.stop(pid)
  end
end
