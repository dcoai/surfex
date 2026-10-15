defmodule Surfex.IssuesTest do
  # #266 (C.2 part 3): a deferral goes stale when its issue closes or the unit is built;
  # issue states come from the project's declared command, asked only under --issues
  # (§13.7).
  use ExUnit.Case, async: false

  alias Surfex.{Issues, Log, Status}
  alias Surfex.Log.Entry
  alias Surfex.Scan
  alias Surfex.Scan.Markdown
  alias Surfex.Status.{Config, Report}

  @script Path.expand("../fixtures/issues/state.exs", __DIR__)
  @command ["elixir", @script, "{n}", "{ref}", "{project}"]

  @spec_text """
  # Views
  <!-- surfex: views -->
  <!-- surfex: deferred #12: past v1 -->

  Views later.

  # Gate
  <!-- surfex: gate -->

  <!-- surfex: gate-block -->
  <!-- surfex: deferred acme/tools#40 -->
  The gate block.
  <!-- /surfex -->
  """

  defp spec, do: Markdown.sections(@spec_text, "spec.md")

  defp stale(status), do: Enum.map(status.stale_deferrals, &{&1.unit, &1.reason})

  defp derive(scans, entries, opts), do: Status.derive(scans, entries, [], opts)

  @tag verifies: ["deferral-stale", "stale-deferrals"]
  test "a deferral is stale once its issue closes or its unit is built" do
    scans = spec()

    closed = derive(scans, [], issues: %{"#12" => :closed, "acme/tools#40" => :open})
    assert stale(closed) == [{"spec.md#views", :closed}]
    assert Status.failing?(closed)
    assert Report.text(closed) =~ "spec spec.md#views deferred by #12: its issue is closed"
    assert [%{"reason" => "closed"}] = JSON.decode!(Report.json(closed))["stale_deferrals"]

    assert [%{"issue" => "open"}, %{"issue" => "closed"}] =
             JSON.decode!(Report.json(closed))["deferred"]

    open = derive(scans, [], issues: %{"#12" => :open, "acme/tools#40" => :open})
    assert stale(open) == []
    refute Status.failing?(open)

    unanswered = derive(scans, [], issues: %{"#12" => :open})
    assert stale(unanswered) == [{"spec.md#gate-block", :unresolved}]

    unasked = derive(scans, [], [])
    assert stale(unasked) == []
    assert Enum.map(unasked.deferred, & &1.issue) == [nil, nil]

    # A test verifying the deferred unit itself: built, with or without issue states.
    views = Enum.find(scans, &(&1.id == "spec.md#views"))

    t = %Scan{
      kind: :test,
      id: "T: views",
      hash: "t",
      declares: [{:verifies, "views"}],
      location: %{file: "test/v_test.exs", lines: {1, 2}}
    }

    verifies =
      Entry.new!(
        at: "2026-10-14T10:00:00Z",
        op: :relate,
        type: :verifies,
        basis: :review,
        by: "t",
        note: "checked",
        ends: [
          %{kind: :test, id: t.id, hash: t.hash},
          %{kind: :spec, id: views.id, hash: views.hash}
        ]
      )

    built = derive(scans ++ [t], [verifies], [])
    assert stale(built) == [{"spec.md#views", :built}]

    assert stale(derive(scans ++ [t], [verifies], issues: %{"#12" => :open})) ==
             [{"spec.md#views", :built}, {"spec.md#gate-block", :unresolved}]
             |> Enum.sort()

    assert_raise ArgumentError, ~r/issues: must be a map/, fn ->
      derive(scans, [], issues: [:closed])
    end
  end

  describe "the declared resolver" do
    @describetag verifies: "issue-resolver"

    @tag :tmp_dir
    @tag verifies: ["issue-resolver", "stale-deferrals"]
    test "states come from the command's output, with refs substituted and no shell", %{
      tmp_dir: root
    } do
      plain = Config.issues!(issues: [command: @command, project: "fallback/project"])

      assert Issues.states(plain, ["#1", "#3", "acme/tools#4", "#5", "#1"], root) ==
               {:ok,
                %{"#1" => :open, "#3" => :unresolved, "acme/tools#4" => :open, "#5" => :closed}}

      json = Config.issues!(issues: [command: @command, state: "state"])

      # A missing key, or output that isn't JSON, is no state.
      assert Issues.states(json, ["#6"], root) == {:ok, %{"#6" => :unresolved}}
      assert Issues.state(" Opened\n") == :open and Issues.state(nil) == :unresolved

      assert Issues.states(json, ["#2", "#1"], root) ==
               {:ok, %{"#2" => :closed, "#1" => :unresolved}}

      # No shell: a metacharacter is an argument like any other.
      shelled = %{plain | command: ["elixir", @script, "{n};", "{ref}", "{project}"]}
      assert Issues.states(shelled, ["#1"], root) == {:ok, %{"#1" => :unresolved}}

      assert {:error, {"#9", output}} = Issues.states(plain, ["#1", "#9"], root)
      assert output =~ "the tracker is down"

      assert Config.issues!([]) == nil

      for bad <- [
            [command: []],
            [command: "glab"],
            [cmd: ["x"]],
            [command: ["x"], state: :state],
            :x
          ] do
        assert_raise ArgumentError, ~r/issues: must be/, fn -> Config.issues!(issues: bad) end
      end
    end

    @tag :tmp_dir
    @tag verifies: ["issue-resolver", "stale-deferrals"]
    test "mix surfex.status --issues asks the tracker, and fails on what it can't answer", %{
      tmp_dir: root
    } do
      File.write!(Path.join(root, "spec.md"), """
      # Views
      <!-- surfex: deferred #1 -->

      Views later.

      # Gate
      <!-- surfex: deferred #3 -->

      The gate.
      """)

      config = fn command ->
        inspect(sources: ["spec.md"], issues: [command: command])
      end

      File.write!(Path.join(root, ".surfex.exs"), config.(@command))
      Log.init(root)

      run = fn args ->
        File.cd!(root, fn ->
          Mix.shell(Mix.Shell.Process)
          Mix.Tasks.Surfex.Status.run(args)
        end)
      end

      # Without --issues nothing runs and nothing is judged stale.
      run.([])
      assert_received {:mix_shell, :info, [text]}
      refute text =~ "Stale deferrals"

      # #3 answers garbage: unresolved, so the check fails under --issues.
      assert_raise Mix.Error, ~r/relations need attention/, fn -> run.(["--issues"]) end
      assert_received {:mix_shell, :info, [text]}
      assert text =~ "spec spec.md#Gate deferred by #3: the tracker couldn't say"
      refute text =~ "#1:"

      File.write!(
        Path.join(root, ".surfex.exs"),
        config.(["elixir", @script, "9", "{ref}", "{project}"])
      )

      assert_raise Mix.Error, ~r/asking the tracker about #1: .*the tracker is down/s, fn ->
        run.(["--issues"])
      end

      File.write!(Path.join(root, ".surfex.exs"), inspect(sources: ["spec.md"]))
      assert_raise Mix.Error, ~r/--issues needs issues:/, fn -> run.(["--issues"]) end
    after
      Mix.shell(Mix.Shell.IO)
    end
  end
end
