defmodule Surfex.InertTagsTest do
  # #207 (B.3), #246: a verifies declaration counts only from the test or property block
  # it applies to. A tag anywhere else verifies nothing, and is reported so a misplaced tag
  # is visible rather than silently ignored.
  use ExUnit.Case, async: true
  @moduletag :tmp_dir

  alias Surfex.{Scan, Status}
  alias Surfex.Status.{Config, Report}

  @tests ~S'''
  defmodule AppTest do
    use ExUnit.Case
    @moduletag verifies: "taken-by-module"

    @tag verifies: "taken"
    test "one", do: assert(true)

    @tag verifies: "for-taken"
    for n <- [1, 2] do
      test "case #{n}", do: assert(n > 0)
    end

    describe "empty" do
      @describetag verifies: "describe-over-nothing"
      def helper, do: :ok
    end

    describe "full" do
      @describetag verifies: "describe-taken"
      test "two", do: assert(true)
      @tag verifies: "trailing-in-describe"
    end

    @tag verifies: ["trailing", "also"]
  end

  defmodule NoTests do
    @moduletag verifies: "module-over-nothing"
    def helper, do: :ok
  end
  '''

  @support ~S'''
  defmodule App.Support do
    @moduletag verifies: "support-module"
    @tag verifies: "support-tag"
    def fixture, do: :ok
  end
  '''

  defp project(root) do
    files = %{
      "spec.md" => "# App\n\n```test:taken\none\n```\n",
      "lib/app.ex" => "defmodule App do\n  def f, do: 1\nend\n",
      "test/app_test.exs" => @tests,
      "test/support/support.ex" => @support
    }

    for {path, text} <- files do
      File.mkdir_p!(Path.dirname(Path.join(root, path)))
      File.write!(Path.join(root, path), text)
    end

    root
  end

  describe "inert tags" do
    @describetag verifies: "inert-tags"

    test "a tag no test takes, or any tag in test/support, is inert, with its file, line, ids and reason",
         %{tmp_dir: root} do
      inert = root |> project() |> Scan.ExUnit.inert(["test/*_test.exs"])

      assert Enum.map(inert, &{&1.file, &1.ids, &1.reason}) == [
               {"test/app_test.exs", ["describe-over-nothing"], :no_test},
               {"test/app_test.exs", ["trailing-in-describe"], :no_test},
               {"test/app_test.exs", ["trailing", "also"], :no_test},
               {"test/app_test.exs", ["module-over-nothing"], :no_test},
               {"test/support/support.ex", ["support-module"], :support},
               {"test/support/support.ex", ["support-tag"], :support}
             ]

      assert [%{line: 14} | _] = inert

      taken = ["taken", "for-taken", "taken-by-module", "describe-taken"]
      refute Enum.any?(inert, &Enum.any?(&1.ids, fn id -> id in taken end))
    end

    test "support code scanned as tests is judged as tests", %{tmp_dir: root} do
      inert = root |> project() |> Scan.ExUnit.inert(["test/*_test.exs", "test/support/*.ex"])

      assert [{"test/support/support.ex", :no_test}] =
               for(%{file: "test/support/" <> _ = f, reason: r} <- inert, uniq: true, do: {f, r})
    end

    test "status lists them in its text, JSON and golden, and doesn't fail on them",
         %{tmp_dir: root} do
      config = [sources: ["spec.md"], tests: ["test/*_test.exs"]]
      {scans, options} = Config.load(config, project(root), "App")
      assert length(options[:inert]) == 6

      status = Status.derive(scans, [], [], options)
      plain = Status.derive(scans, [], [], Keyword.delete(options, :inert))
      assert Status.failing?(status) == Status.failing?(plain)

      assert Report.text(status) =~
               "Inert (a verifies tag outside any test: it verifies nothing):\n" <>
                 "  test/app_test.exs:14 verifies describe-over-nothing: no test or property block takes it"

      assert Report.text(status) =~ "verifies support-tag: in test/support, which runs no test"

      json = status |> Report.json() |> Surfex.Log.Entry.json()

      assert %{
               "file" => "test/support/support.ex",
               "reason" => "support",
               "ids" => ["support-tag"]
             } =
               List.last(json["inert"])

      assert %{heading: "inert", rows: rows} =
               Enum.find(Report.golden(status).groups, &(&1.heading == "inert"))

      assert length(rows) == 6
      refute Enum.any?(Report.golden(plain).groups, &(&1.heading == "inert"))
    end
  end

  @tag verifies: "inert-no-evidence"
  test "a module with a tag and no test, and a helper in test/support, give no test record",
       %{tmp_dir: root} do
    root = project(root)
    records = Scan.ExUnit.records(root, ["test/*_test.exs", "test/support/*.ex"])
    declared = for r <- records, {:verifies, id} <- r.declares, uniq: true, do: id

    for id <- ["module-over-nothing", "support-module", "support-tag", "describe-over-nothing"],
        do: refute(id in declared, "#{id} made a test record")

    assert "taken" in declared
    refute Enum.any?(records, &String.starts_with?(&1.id, "NoTests"))
    refute Enum.any?(records, &String.starts_with?(&1.id, "App.Support"))
  end
end
