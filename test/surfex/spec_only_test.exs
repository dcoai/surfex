defmodule Surfex.SpecOnlyTest do
  # #316 (for #297): `mix surfex.status --spec` reads the spec side alone, for a repository
  # that holds a spec another implements (§13.16).
  # The task reads the working directory, which is global.
  use ExUnit.Case, async: false

  alias Surfex.{Log, Scan}
  alias Surfex.Log.Entry
  alias Surfex.Status.Config

  @moduletag :tmp_dir
  @project Path.expand("../fixtures/elixir_project", __DIR__)

  @config ~S"""
  [
    sources: ["spec/*.md"],
    namespace: "MyLib",
    unit_refs: [~r/^spec\/(?<chapter>\d+) §(?<id>[a-z-]+)$/]
  ]
  """

  @api """
  # 1. `MyLib.Env`

  ```elixir contract
  @spec check(t, keyword) :: :ok
  ```

  ## 1.1 Using it

  Call `MyLib.Env.check/2`, then `MyLib.Other.run/1`.
  """

  # The same contract, stated otherwise: restated, listed, never failing (§13.10).
  @notes """
  # 2. `MyLib.Env` again

  ```elixir contract
  @spec check(t, list) :: :ok
  ```

  # 3. Decisions
  <!-- surfex: past-later -->

  Views wait.
  """

  defp so_write(root, path, text) do
    file = Path.join(root, path)
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, text)
  end

  defp so_spec_repo(root) do
    so_write(root, ".surfex.exs", @config)
    so_write(root, "spec/01-api.md", @api)
    so_write(root, "spec/02-notes.md", @notes)
  end

  defp so_task(root, args) do
    File.cd!(root, fn ->
      Mix.shell(Mix.Shell.Process)
      Mix.Tasks.Surfex.Status.run(args)
    end)
  after
    Mix.shell(Mix.Shell.IO)
  end

  defp so_output do
    receive do
      {:mix_shell, :info, [text]} -> text
    after
      0 -> flunk("no output")
    end
  end

  @tag verifies: ["spec-only-reads", "spec-only"]
  test "a spec-only repository reads clean under --spec, saying what it doesn't read",
       %{tmp_dir: root} do
    so_spec_repo(root)
    refute File.exists?(Path.join(root, "lib"))
    refute File.exists?(Path.join(root, ".surfex"))

    so_task(root, ["--spec"])
    text = so_output()

    assert text =~
             "spec only (--spec): code, relations, the log and evidence are not read\n" <>
               "spec status: ok\n"

    # Restated is listed and doesn't fail; nothing about code or relations.
    assert text =~ "Restated (a contract stated differently in several files)"
    assert text =~ "contract MyLib.Env.check/2"
    refute text =~ "Broken citations"
    refute text =~ "relation status"

    so_task(root, ["--spec", "--format", "json"])
    json = JSON.decode!(so_output())

    assert %{"mode" => "spec", "failing" => false, "scan_errors" => [], "spec_warnings" => []} =
             json

    assert [%{"contract" => "MyLib.Env.check/2"}] = json["restated"]
    assert json["units"]["contract"] == 2
    refute Map.has_key?(json, "relations")
  end

  @tag verifies: ["spec-only-reads", "spec-only", "contract-arity"]
  test "under --spec a cited arity no contract states fails", %{tmp_dir: root} do
    so_spec_repo(root)
    so_write(root, "spec/01-api.md", String.replace(@api, "check/2`,", "check/1`,"))

    assert_raise Mix.Error, ~r/the spec needs attention/, fn -> so_task(root, ["--spec"]) end
    text = so_output()
    assert text =~ "spec status: FAILING"
    assert text =~ "Spec shape (warnings; under --spec a cited arity fails)"
    assert text =~ "`MyLib.Env.check/1` cites an arity no contract states"

    # A function no contract states, at any arity, is not checked: nothing can judge it.
    refute text =~ "MyLib.Other.run/1"

    assert_raise Mix.Error, fn -> so_task(root, ["--spec", "--format", "json"]) end
    json = JSON.decode!(so_output())
    assert %{"failing" => true, "mode" => "spec"} = json
    assert [%{"kind" => "contract_arity", "line" => 9}] = json["spec_warnings"]
  end

  @tag verifies: ["spec-only-reads", "spec-only", "unit-deferrals"]
  test "under --spec an unresolved deferral citation is a scan error, a stale one fails",
       %{tmp_dir: root} do
    so_spec_repo(root)
    views = "\n# 4. Views\n<!-- surfex: deferred spec/02 §no-such: past v1 -->\n\nLater.\n"
    so_write(root, "spec/02-notes.md", @notes <> views)

    error = assert_raise Scan.Errors, fn -> so_task(root, ["--spec"]) end
    assert so_output() =~ "spec only (--spec)"
    assert Exception.message(error) =~ "spec/02-notes.md:"
    assert Exception.message(error) =~ "is no spec unit"

    assert_raise Mix.Error, ~r/1 scan errors/, fn ->
      so_task(root, ["--spec", "--format", "json"])
    end

    assert %{"mode" => "spec", "failing" => true, "scan_errors" => [_]} =
             JSON.decode!(so_output())

    # Resolved through unit_refs:, but pinning no version: stale, and failing.
    so_write(root, "spec/02-notes.md", @notes <> String.replace(views, "no-such", "past-later"))
    assert_raise Mix.Error, ~r/the spec needs attention/, fn -> so_task(root, ["--spec"]) end
    assert so_output() =~ "spec spec/02-notes.md#4. Views deferred by spec/02 §past-later"
  end

  @tag verifies: ["spec-only-reads", "spec-only"]
  test "a flag reading what --spec skips is refused with it, naming it", %{tmp_dir: root} do
    so_spec_repo(root)

    error =
      assert_raise Mix.Error, fn -> so_task(root, ["--spec", "--evidence", "--no-planned"]) end

    assert error.message =~
             "--spec reads the spec alone, so it takes none of --planned, --evidence"
  end

  @tag verifies: ["spec-only-reads", "spec-only"]
  test "without --spec the same repository reads as a full status", %{tmp_dir: root} do
    so_spec_repo(root)

    assert_raise Mix.Error, ~r/relations need attention/, fn -> so_task(root, []) end
    text = so_output()
    assert text =~ "relation status: FAILING\n  (no relations)"
    assert text =~ "Broken citations (the spec names what the code doesn't have)"
    refute text =~ "spec only"
  end

  @tag verifies: ["spec-only-parity", "spec-only"]
  test "in a project with code and a log, --spec gives the full run's spec-side lists",
       %{tmp_dir: root} do
    File.cp_r!(@project, root)

    so_write(root, "spec/01-cart.md", """
    # 1. `MyApp.Cart`

    ```elixir contract
    @spec total() :: integer
    ```

    ## 1.1 Totals

    `MyApp.Cart.total/1` sums the cart; `MyApp.Cart.add/2` adds to it.

    | Key | Meaning |
    |---|---|
    | a, b | two things |
    """)

    so_write(root, "spec/02-more.md", """
    # 2. `MyApp.Cart` again

    ```elixir contract
    @spec total() :: non_neg_integer
    ```
    """)

    so_write(root, ".surfex.exs", ~s([sources: ["spec/*.md"], namespace: "MyApp"]))

    Log.init(root)
    scans = Config.scans([sources: ["spec/*.md"]], root) |> Map.new(&{&1.id, &1})
    spec = scans["spec/01-cart.md#1. `MyApp.Cart`/1.1 Totals"]
    code = scans["MyApp.Cart.add/2"]

    Log.append(root, [
      Entry.new!(
        at: "2026-10-16T10:00:00Z",
        op: :relate,
        type: :implements,
        ends: [
          %{kind: :spec, id: spec.id, hash: spec.hash},
          %{kind: :code, id: code.id, hash: code.hash}
        ]
      )
    ])

    # The full run fails on the broken citation; --spec on the cited arity.
    assert_raise Mix.Error, fn -> so_task(root, ["--format", "json"]) end
    full = JSON.decode!(so_output())
    assert_raise Mix.Error, fn -> so_task(root, ["--spec", "--format", "json"]) end
    spec_only = JSON.decode!(so_output())

    keys = ["units", "spec_warnings", "list_keys", "restated", "stale_deferrals"]
    assert Map.take(spec_only, keys) == Map.take(full, keys)

    assert [%{"kind" => "contract_arity"}] = full["spec_warnings"]
    assert [_] = full["restated"]
    assert full["relations"] != []
    refute Map.has_key?(spec_only, "relations")
  end
end
