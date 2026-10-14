defmodule Surfex.DeclaredFormsTest do
  # #250: a project that already records what its tests verify, in a form of its own,
  # declares the form, and the test scanner reads it as verifies declarations (§11.6).
  use ExUnit.Case, async: true
  @moduletag :tmp_dir

  alias Surfex.{Scan, Select}
  alias Surfex.Scan.ExUnit, as: Tests
  alias Surfex.Status.Config

  @strip ~r/@[0-9a-f]+$/
  @forms [
    %{kind: :tag, name: :validates, strip: @strip},
    %{kind: :attribute, name: :validates, strip: @strip}
  ]

  @source ~S'''
  defmodule M.EngineTest do
    use ExUnit.Case
    @moduletag validates: ["Engine.1@aa11"]

    @tag validates: ["Engine.15.2@abc123", "Engine.15.3@def456"]
    test "tagged" do
      assert true
    end

    test "module level" do
      assert "§Engine.7 is only prose" != ""
    end

    @validates ["Engine.4@0f0f"]
    test "attribute" do
      assert true
    end

    describe "d" do
      @describetag validates: "Engine.9@0a"
      test "in describe", do: assert(true)
    end

    @tag verifies: "own"
    @tag validates: "Engine.5@1"
    test "both", do: assert(true)
  end
  '''

  defp by_name(forms) do
    @source
    |> Tests.tests("test/engine_test.exs", [], [], [], forms)
    |> Map.new(&{&1.id |> String.split(": ") |> List.last(), &1})
  end

  @tag verifies: ["declared-forms", "declared-forms-section"]
  test "a declared tag or attribute form is read as verifies declarations, its strip removed" do
    tests = by_name(@forms)
    ids = fn name -> for {:verifies, id} <- tests[name].declares, do: id end

    # A test's own tag replaces its module's, key by key, as ExUnit merges tags.
    assert ids.("tagged") == ["Engine.15.2", "Engine.15.3"]
    # A bare § mention in a test's prose is no declaration.
    assert ids.("module level") == ["Engine.1"]
    # The attribute applies to the next test; the module's tag form still does too.
    assert ids.("attribute") == ["Engine.1", "Engine.4"]
    assert ids.("in describe") == ["Engine.9"]
    assert ids.("both") == ["own", "Engine.5"]

    # mix test --only verifies:id reads the verifies tag alone: a form's ids are never
    # selectable by it, and a verifies tag of one id still is.
    assert tests["tagged"].unselectable == ["Engine.15.2", "Engine.15.3"]
    assert tests["both"].unselectable == ["Engine.5"]

    # Without the form declared, the tag and the attribute declare nothing.
    plain = by_name([])
    assert plain["tagged"].declares == []
    assert plain["both"].declares == [{:verifies, "own"}]
    assert plain["both"].unselectable == []

    # A value that can't be read raises, naming the form's key.
    bad = ~S'''
    defmodule M.BadTest do
      use ExUnit.Case
      @tag validates: some_ids()
      test "x", do: assert(true)
    end
    '''

    error =
      assert_raise ArgumentError, fn ->
        Tests.tests(bad, "test/bad_test.exs", [], [], [], @forms)
      end

    assert error.message =~ "test/bad_test.exs:3: validates: must be a string or a list"
  end

  @tag verifies: ["declared-forms", "declared-forms-section"]
  test "a declared form no test takes is inert", %{tmp_dir: root} do
    File.mkdir_p!(Path.join(root, "test"))

    File.write!(Path.join(root, "test/trailing_test.exs"), ~S'''
    defmodule M.TrailingTest do
      use ExUnit.Case

      test "x", do: assert(true)

      @tag validates: ["Engine.2@ab"]
      @validates "Engine.3@cd"
    end
    ''')

    assert [
             %{line: 6, ids: ["Engine.2"], reason: :no_test},
             %{line: 7, ids: ["Engine.3"], reason: :no_test}
           ] = Tests.inert(root, ["test/*_test.exs"], @forms)

    assert Tests.inert(root, ["test/*_test.exs"]) == []
  end

  @tag verifies: ["declared-forms-config", "declared-forms-section"]
  test "declares: is read and validated; its ids resolve through unit_refs: and select", %{
    tmp_dir: root
  } do
    File.mkdir_p!(Path.join(root, "spec"))
    File.mkdir_p!(Path.join(root, "test"))
    File.write!(Path.join(root, "spec/03-engine.md"), "# 15 Engine\n\n## 15.2 Limits\n\nText.\n")

    File.write!(Path.join(root, "test/engine_test.exs"), ~S'''
    defmodule M.EngineTest do
      use ExUnit.Case

      @tag validates: ["03.15.2@abc123"]
      test "limits", do: assert(true)
    end
    ''')

    config = [
      sources: ["spec/*.md"],
      heading_ids: :section_number,
      unit_refs: [~r/^(?<chapter>\d\d)\.(?<id>[\w.]+)$/],
      tests: ["test/*_test.exs"],
      declares: [verifies: [{:tag, :validates, strip: @strip}]]
    ]

    assert [%{kind: :tag, name: :validates, strip: strip}] = Config.declares!(config)
    assert Regex.source(strip) == Regex.source(@strip)
    scans = Config.scans(config, root)
    [test] = for %Scan{kind: :test} = t <- scans, do: t
    assert test.declares == [{:verifies, "spec/03-engine.md#15.2"}]
    assert test.unselectable == ["03.15.2"]

    # mix surfex.test selects it by its declaration, as it selects a list's members.
    assert {:ok, [^test]} = Select.tests(scans, ["spec/03-engine.md#15.2"])

    status = Surfex.Status.derive(scans, [])
    assert [%{test: "M.EngineTest: limits", ids: ["03.15.2"]}] = status.unselectable
    assert [%{spec: "spec/03-engine.md#15.2"}] = status.unrecorded

    # Malformed forms are refused, naming them.
    for bad <- [
          [verifies: []],
          [validates: [{:tag, :validates}]],
          [verifies: [{:tag, :verifies}]],
          [verifies: [{:comment, :validates}]],
          [verifies: [{:tag, :validates, strip: "@.*"}]],
          [verifies: [{:attribute, :validates, other: 1}]]
        ] do
      assert_raise ArgumentError, ~r/declares:/, fn -> Config.declares!(declares: bad) end
    end

    assert Config.declares!([]) == []

    assert [%{kind: :attribute, strip: nil}] =
             Config.declares!(declares: [verifies: [{:attribute, :v}]])
  end
end
