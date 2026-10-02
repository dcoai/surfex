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
  @other "MyApp.Cart.add/2"

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

  @tag verifies: ["recording-by-name", "log-append-only", "surfex"]
  test "relate → dangling → confirm → conflict across branches → resolve", %{root: root} do
    # A structural relation, which a judgement can confirm: code is only ever validated
    # by evidence or a review (§18).
    task(root, Mix.Tasks.Surfex.Relate, [@function, @other, "--type", "depends_on"])
    commit(root, "relate")
    assert %{"state" => "current"} = status(root)

    # An edit to the function dangles the relation, and says which side moved.
    edit_total(root, 1)
    commit(root, "edit")
    assert %{"state" => "dangling", "ends" => ends} = failing_status(root)

    assert %{"changed" => true, "location" => %{"file" => "lib/my_app/cart.ex"}} =
             Enum.find(ends, &(&1["kind"] == "code"))

    assert %{"changed" => false} = Enum.find(ends, &(&1["id"] == @other))

    task(root, Mix.Tasks.Surfex.Confirm, [
      @function,
      @other,
      "--type",
      "depends_on",
      "--note",
      "total/0 still uses add/2"
    ])

    commit(root, "confirm")
    assert %{"state" => "current"} = status(root)

    # Another edit, then both branches confirm it without seeing each other.
    edit_total(root, 2)
    commit(root, "edit again")
    git(root, ["checkout", "--quiet", "-b", "other"])

    task(root, Mix.Tasks.Surfex.Confirm, [
      @function,
      @other,
      "--type",
      "depends_on",
      "--note",
      "checked on other"
    ])

    commit(root, "confirm on other")
    git(root, ["checkout", "--quiet", "main"])

    task(root, Mix.Tasks.Surfex.Confirm, [
      @function,
      @other,
      "--type",
      "depends_on",
      "--note",
      "checked on main"
    ])

    commit(root, "confirm on main")
    git(root, ["merge", "--quiet", "--no-edit", "other"])

    assert %{"state" => "conflicted", "tips" => [tip, _]} = failing_status(root)

    task(root, Mix.Tasks.Surfex.Resolve, [
      @function,
      @other,
      "--type",
      "depends_on",
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
  @tag verifies: ["recording-by-name", "process-proposed", "process-one-at-a-time"]
  test "plan → planned → write the code → proposed until validated", %{root: root} do
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

    # The code exists: the relation is a claim until evidence or a review validates it,
    # and saying so by hand is refused (§18).
    assert %{"state" => "proposed", "ends" => ends} = failing_status(root)
    assert %{"changed" => true, "planned" => false} = Enum.find(ends, &(&1["id"] == planned))

    error =
      assert_raise Mix.Error, fn ->
        task(root, Mix.Tasks.Surfex.Confirm, [
          @section,
          planned,
          "--type",
          "implements",
          "--note",
          "written"
        ])
      end

    assert error.message =~ "implements is validated by evidence or a review"

    # A review validates it: a test declared against the section, examined against it and
    # run green against the code; then `mix surfex.validate` records both relations.
    File.write!(
      Path.join(root, ".surfex.exs"),
      ~s([sources: ["spec.md"], tests: ["test/*_test.exs"]])
    )

    File.mkdir_p!(Path.join(root, "test"))

    File.write!(Path.join(root, "test/cart_test.exs"), """
    defmodule MyApp.CartTest do
      use ExUnit.Case

      @tag verifies: "spec.md#Totals"
      test "an empty cart stays empty" do
        assert MyApp.Cart.discount([]) == []
      end
    end
    """)

    test_id = "test:MyApp.CartTest: an empty cart stays empty"
    # The tag never failed, so its verifies relation is proposed like the code's.
    task(root, Mix.Tasks.Surfex.Suggest, ["--accept"])
    assert %{"relations" => relations} = failing_json(root)

    assert Enum.frequencies_by(relations, &{&1["type"], &1["state"]}) == %{
             {"implements", "proposed"} => 1,
             {"verifies", "proposed"} => 1,
             {"tests", "current"} => 2
           }

    commit(root, "a test for discount/1")
    drain()

    validate = [test_id, @section, "--note", "the test checks the section's one claim"]

    # Without a green run there is nothing to review against.
    error = assert_raise Mix.Error, fn -> task(root, Mix.Tasks.Surfex.Validate, validate) end
    assert error.message =~ "no green run"

    run_test(root, nil)

    # A review says what it checked.
    error =
      assert_raise Mix.Error, fn ->
        task(root, Mix.Tasks.Surfex.Validate, Enum.take(validate, 2))
      end

    assert error.message =~ "a note is required"

    task(root, Mix.Tasks.Surfex.Validate, validate)
    assert drain() |> Enum.count(&(&1 =~ "recorded relate")) == 2

    task(root, Mix.Tasks.Surfex.Status, ["--format", "json", "--validated"])
    %{"relations" => relations, "triangle" => []} = decode_report()
    assert Enum.map(relations, & &1["state"]) |> Enum.uniq() == ["current"]
  end

  @tag verifies: "recording"
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
  @tag verifies: ["suggest-proposes"]
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

    # The failing test, then the test relation, recorded on that failing run (§18).
    run_test(root, {:failed, []}, 6)
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

    # The code: the planned relation is proposed until validated, and suggest adds tests.
    path = Path.join(root, "lib/my_app/cart.ex")

    File.write!(
      path,
      String.replace(
        File.read!(path),
        "  def total,",
        "  def discount(cart), do: cart\n\n  def total,"
      )
    )

    # The code, green, then the code relation on the red run and the green one. The test
    # names MyApp.Cart too, whose public surface grew: the test still names it, so suggest
    # refreshes that tests relation (§15).
    task(root, Mix.Tasks.Surfex.Suggest, ["--accept"])
    run_test(root, nil, 6)
    task(root, Mix.Tasks.Surfex.Confirm, ["--evidence"])
    commit(root, "code")

    json = passing_json(root)
    assert json["triangle"] == []
    assert Enum.all?(json["relations"], &(&1["state"] == "current"))

    # The test tests the function it calls and the module it names.
    assert Enum.sort(Enum.map(json["relations"], & &1["type"])) ==
             ["implements", "refines", "tests", "tests", "verifies"]
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
  @tag verifies: ["evidence-confirms", "purpose"]
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
    assert Enum.any?(relations, &(&1["type"] == "implements" and &1["state"] == "proposed"))

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
  defp run_test(root, state, line \\ 5) do
    {:ok, pid} = GenServer.start_link(Surfex.ExUnitFormatter, surfex_root: root)
    GenServer.cast(pid, {:suite_started, []})
    file = Path.join(root, "test/cart_test.exs")

    test = %ExUnit.Test{
      name: :t,
      module: MyApp.CartTest,
      state: state,
      tags: %{file: file, line: line}
    }

    GenServer.cast(pid, {:test_finished, test})
    GenServer.cast(pid, {:suite_finished, %{}})
    GenServer.stop(pid)
  end

  # #73: the tests reflect the spec and the code passes them, but the result is wrong.
  @tag verifies: "mark-recorded"
  test "mark → reported → --no-marks fails → withdraw; a spec change resolves a mark",
       %{root: root} do
    note = "totals ignore discounts in use"
    task(root, Mix.Tasks.Surfex.Mark, [@section, "--needs-update", "--note", note])
    assert Enum.any?(drain(), &(&1 =~ "recorded mark needs_update  spec #{@section}@"))
    commit(root, "mark")

    # Reported, and not failing unless asked.
    task(root, Mix.Tasks.Surfex.Status, [])
    assert drain() |> Enum.join("\n") =~ "Marked (the spec needs an update):\n  spec #{@section}"
    assert_raise Mix.Error, fn -> task(root, Mix.Tasks.Surfex.Status, ["--no-marks"]) end
    drain()

    task(root, Mix.Tasks.Surfex.History, [@section])
    assert Enum.any?(drain(), &(&1 =~ "mark needs_update  spec #{@section}@" and &1 =~ note))

    # Withdrawn by name: nothing open.
    task(root, Mix.Tasks.Surfex.Mark, [@section, "--withdraw", "--note", "it was a test cart"])
    drain()
    task(root, Mix.Tasks.Surfex.Status, ["--no-marks"])
    refute drain() |> Enum.join("\n") =~ "Marked"

    # Marked again, then the spec changes: the mark is resolved.
    task(root, Mix.Tasks.Surfex.Mark, [@section, "--needs-update", "--note", note])
    File.write!(Path.join(root, "spec.md"), "# Totals\n\nA cart's total, after discounts.\n")
    drain()
    task(root, Mix.Tasks.Surfex.Status, ["--no-marks"])
    refute drain() |> Enum.join("\n") =~ "Marked"

    # One of --needs-update or --withdraw, and a note.
    for args <- [[@section, "--note", "x"], [@section, "--needs-update"]] do
      assert_raise Mix.Error, fn -> task(root, Mix.Tasks.Surfex.Mark, args) end
    end
  end

  # #75: found work goes to the environment's own change process; surfex only drafts.
  @tag verifies: "change-hand-off"
  test "mark prints its draft; mix surfex.draft prints, and hands off only with --file",
       %{root: root} do
    note = "totals ignore discounts in use"
    task(root, Mix.Tasks.Surfex.Mark, [@section, "--needs-update", "--note", note])
    printed = drain() |> Enum.join("\n")
    assert printed =~ "# Spec needs an update: #{@section}"
    assert printed =~ note

    task(root, Mix.Tasks.Surfex.Draft, [])
    assert drain() |> Enum.join("\n") =~ "## Steps"

    task(root, Mix.Tasks.Surfex.Draft, ["--format", "json"])
    {json, :ok, _} = drain() |> Enum.join() |> :json.decode(:ok, %{null: nil})
    assert [%{"source" => "mark", "id" => @section}] = json

    # --file hands each draft to process:, here a command that records what it got.
    out = Path.join(root, "handed.txt")
    script = Path.join(root, "hand.exs")
    File.write!(script, "File.write!(#{inspect(out)}, hd(System.argv()))\n")

    File.write!(
      Path.join(root, ".surfex.exs"),
      ~s([sources: ["spec.md"], process: {:command, ["elixir", #{inspect(script)}, "{title}"]}])
    )

    task(root, Mix.Tasks.Surfex.Draft, [])
    refute File.exists?(out)
    task(root, Mix.Tasks.Surfex.Draft, ["--file"])
    assert File.read!(out) == "Spec needs an update: #{@section}"
  end

  # #88: an established suite adopted once, by trust, then moving to evidence.
  @tag verifies: ["baseline-one-shot", "baseline-shrinks"]
  test "adoption: :trust → mix surfex.baseline → confirm --evidence, counted; --no-baseline fails",
       %{root: root} do
    File.write!(Path.join(root, "spec.md"), "# Totals {#totals}\n\nA cart's total.\n")
    File.mkdir_p!(Path.join(root, "test"))

    File.write!(Path.join(root, "test/cart_test.exs"), """
    defmodule MyApp.CartTest do
      use ExUnit.Case

      @tag verifies: "totals"
      test "an empty cart totals nothing" do
        assert MyApp.Cart.total() == 0
      end
    end
    """)

    config = ~s([sources: ["spec.md"], tests: ["test/*_test.exs"]])
    File.write!(Path.join(root, ".surfex.exs"), config)
    task(root, Mix.Tasks.Surfex.Relate, ["spec.md#totals", @function, "--type", "implements"])
    commit(root, "adopting")
    drain()

    # The default is :reevaluate: nothing is trusted.
    baseline = ["--note", "the suite was written test-first and reviewed"]
    error = assert_raise Mix.Error, fn -> task(root, Mix.Tasks.Surfex.Baseline, baseline) end
    assert error.message =~ "adoption: is :reevaluate"

    File.write!(
      Path.join(root, ".surfex.exs"),
      ~s([sources: ["spec.md"], tests: ["test/*_test.exs"], adoption: :trust])
    )

    run_test(root, nil, 5)
    task(root, Mix.Tasks.Surfex.Baseline, baseline)

    assert Enum.any?(
             drain(),
             &(&1 =~
                 "recorded observe baseline  test MyApp.CartTest: an empty cart totals nothing@")
           )

    # One-shot.
    error = assert_raise Mix.Error, fn -> task(root, Mix.Tasks.Surfex.Baseline, baseline) end
    assert error.message =~ "already taken"

    # The baselined test carries the code relation, counted as trusted.
    task(root, Mix.Tasks.Surfex.Suggest, ["--accept"])
    task(root, Mix.Tasks.Surfex.Confirm, ["--evidence"])
    drain()
    task(root, Mix.Tasks.Surfex.Status, ["--validated"])
    assert drain() |> Enum.join("\n") =~ "baseline: 2 relations (adoption: :trust)"

    assert_raise Mix.Error, fn -> task(root, Mix.Tasks.Surfex.Status, ["--no-baseline"]) end
  end

  @tag verifies: "recording-by-name"
  test "move carries a renamed section's relation, retire puts one to rest", %{root: root} do
    # A relation a section takes part in, of a type that needs no validation: refines.
    discounts = "\n# Discounts\n\nOff the total.\n"
    File.write!(Path.join(root, "spec.md"), "# Totals\n\nA cart's total.\n" <> discounts)
    task(root, Mix.Tasks.Surfex.Relate, ["spec.md#Discounts", @section, "--type", "refines"])

    File.write!(
      Path.join(root, "spec.md"),
      "# Totals {#totals}\n\nA cart's total.\n" <> discounts
    )

    task(root, Mix.Tasks.Surfex.Move, [@section, "spec.md#totals"])

    assert %{"state" => "current"} =
             Enum.find(passing_json(root)["relations"], &(&1["state"] != "retired"))

    task(root, Mix.Tasks.Surfex.Retire, [
      "spec.md#Discounts",
      "spec.md#totals",
      "--type",
      "refines"
    ])

    assert Enum.all?(passing_json(root)["relations"], &(&1["state"] == "retired"))
  end
end
