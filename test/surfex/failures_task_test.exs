defmodule Surfex.FailuresTaskTest do
  # #405, #408: a failing test's history, and whether a flip was a flake, a regression or
  # a fix that didn't hold, from the committed transitions alone, with no rerun. The task
  # reads the working directory, which is global.
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  alias Surfex.{Failures, Transitions}

  @project Path.expand("../fixtures/elixir_project", __DIR__)

  setup %{tmp_dir: root} do
    File.cp_r!(@project, root)
    File.write!(Path.join(root, "spec.md"), "# Carts\n\nA cart.\n")

    File.write!(
      Path.join(root, ".surfex.exs"),
      ~s([sources: ["spec.md"], tests: ["test/*_test.exs"]])
    )

    File.mkdir_p!(Path.join(root, "test"))
    File.mkdir_p!(Path.join(root, ".surfex"))

    File.write!(Path.join(root, "test/cart_test.exs"), """
    defmodule MyApp.CartTest do
      use ExUnit.Case

      test "a" do
        assert MyApp.Cart.total() == 0
      end

      test "b" do
        assert MyApp.Cart.total() >= 0
      end
    end
    """)

    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    :ok
  end

  defp task(root, args), do: File.cd!(root, fn -> Mix.Tasks.Surfex.Failures.run(args) end)

  defp json(root, args \\ []) do
    flush()
    task(root, ["--json" | args])
    assert_received {:mix_shell, :info, [out]}
    {:json.decode(out), out}
  end

  defp lines do
    for {:mix_shell, :info, [line]} <- flush(), do: line
  end

  defp flush do
    receive do
      message -> [message | flush()]
    after
      0 -> []
    end
  end

  defp transitions(root, lines) do
    File.write!(Transitions.path(root), Enum.map(lines, &[Surfex.JSON.encode(&1), "\n"]))
  end

  defp flip(test, n, from, to, changed, extra \\ %{}) do
    Map.merge(
      %{
        test: test,
        version: "v1",
        from: from,
        to: to,
        at: "2026-11-17T10:00:0#{n}Z",
        run: "r#{n}",
        commit: "c#{n}",
        code: "d",
        changed: changed
      },
      extra
    )
  end

  defp failure(digest),
    do: %{
      failure: %{
        kind: "assertion",
        line: "Assertion failed",
        location: "test/cart_test.exs:5",
        seed: 1,
        digest: digest
      }
    }

  defp same, do: %{test: false, code: []}
  defp cart, do: %{test: false, code: ["MyApp.Cart.total/0"]}

  @tag verifies: "failure-classes"
  test "each flip is classed by what differed from the run before it", %{tmp_dir: root} do
    a = "MyApp.CartTest: a"

    transitions(root, [
      flip(a, 1, :passed, :failed, nil, failure("x")),
      flip(a, 2, :failed, :passed, same(), %{failed_runs: 3}),
      flip(a, 3, :passed, :failed, cart(), failure("d")),
      flip(a, 4, :failed, :passed, cart(), %{failed_runs: 1}),
      flip(a, 5, :passed, :failed, same(), failure("d")),
      flip(a, 6, :failed, :passed, %{test: true, code: []}),
      flip(a, 7, :passed, :failed, nil, failure("y"))
    ])

    {%{"tests" => [history]}, _} = json(root)

    assert %{"test" => ^a, "state" => "failed", "renamed_from" => []} = history

    assert Enum.map(history["flips"], & &1["class"]) ==
             ~w(new nondeterministic code_changed code_changed recurred test_changed unknown)

    assert Enum.at(history["flips"], 1)["failed_runs"] == 3

    task(root, [])
    text = Enum.join(lines(), "\n")
    assert text =~ "Failing now: 1 of 1 with a history"
    assert text =~ "#{a}: failed, 7 flips"
    assert text =~ "2026-11-17T10:00:03Z  passed→failed  code changed: MyApp.Cart.total/0  c3"
    assert text =~ "assertion at test/cart_test.exs:5, seed 1, digest d: Assertion failed"
    assert text =~ "after 3 failed runs"
    assert text =~ "recurred"
  end

  @tag verifies: "failure-classes"
  test "a renamed test keeps its history; an id filters the report; no flips says so", %{
    tmp_dir: root
  } do
    task(root, [])
    assert lines() == ["no test has failed: .surfex/transitions.log has no flips"]

    # The old id's last version is b's current one: b was renamed from it.
    config = Surfex.Status.Config.read!(Path.join(root, ".surfex.exs"))

    [b_hash] =
      for %Surfex.Scan{kind: :test, id: "MyApp.CartTest: b", hash: h} <-
            Surfex.Status.Config.scans(config, root),
          do: h

    old = "MyApp.OldCartTest: b"

    transitions(root, [
      flip(old, 1, :passed, :failed, nil, Map.put(failure("x"), :version, b_hash)),
      flip("MyApp.CartTest: b", 2, :failed, :passed, same(), %{version: b_hash}),
      flip("MyApp.CartTest: a", 3, :passed, :failed, nil, failure("z"))
    ])

    {%{"tests" => tests}, out} = json(root, ["test:MyApp.CartTest: b"])

    assert [%{"test" => "MyApp.CartTest: b", "renamed_from" => [^old], "state" => "passed"}] =
             tests

    assert length(hd(tests)["flips"]) == 2

    # The JSON's keys are sorted, as all surfex JSON is.
    assert Surfex.JSON.encode(:json.decode(out)) == out
  end

  @tag verifies: "failure-judgements"
  test "a judgement is its own line on a named transition, and never edits one", %{tmp_dir: root} do
    a = "MyApp.CartTest: a"

    transitions(root, [
      flip(a, 1, :passed, :failed, same(), failure("x")),
      flip(a, 2, :failed, :passed, cart())
    ])

    before = File.read!(Transitions.path(root))

    assert_raise Mix.Error, ~r/--judge needs --note/, fn -> task(root, ["--judge", a]) end

    task(root, ["--judge", "test:" <> a, "--note", "fixed: shared table"])

    assert_received {:mix_shell, :info,
                     [
                       "recorded judgement on MyApp.CartTest: a at 2026-11-17T10:00:02Z: fixed: shared table"
                     ]}

    task(root, [
      "--judge",
      a,
      "--at",
      "2026-11-17T10:00:01Z",
      "--note",
      "flake: identical versions"
    ])

    assert_raise Mix.Error,
                 ~r/no transition at 2026-11-17T10:00:09Z: its transitions are at/,
                 fn ->
                   task(root, ["--judge", a, "--at", "2026-11-17T10:00:09Z", "--note", "n"])
                 end

    assert_raise Mix.Error, ~r/MyApp.CartTest: b has no transitions/, fn ->
      task(root, ["--judge", "MyApp.CartTest: b", "--note", "n"])
    end

    assert File.read!(Transitions.path(root)) == before

    assert [%{at: "2026-11-17T10:00:02Z"}, %{at: "2026-11-17T10:00:01Z"}] =
             Failures.judgements(root)

    {%{"tests" => [history]}, _} = json(root)

    assert [
             [%{"note" => "flake: identical versions"}],
             [%{"note" => "fixed: shared table", "by" => _}]
           ] =
             Enum.map(history["flips"], & &1["judgements"])

    task(root, [])
    assert Enum.join(lines(), "\n") =~ ~r/judged \S+( by [^:]+)?: flake: identical versions/
  end
end
