defmodule Surfex.ScanErrorsTest do
  # #292: a scan reads past each error it meets and reports them together, once.
  # The task reads the working directory, which is global.
  use ExUnit.Case, async: false

  alias Surfex.Scan
  alias Surfex.Scan.Markdown

  @moduletag :tmp_dir
  @project Path.expand("../fixtures/elixir_project", __DIR__)

  # A contract fence whose signature nothing places: no module in its head, no defmodule,
  # no module: and no heading naming one (§11.9).
  @unplaced """
  <!-- surfex: contract -->
  ```elixir
  @spec open(term) :: :ok
  ```
  """

  defp spec_with_unplaced(n),
    do: "# Notes\n\n" <> Enum.map_join(1..n, "\nText.\n\n", fn _ -> @unplaced end)

  defp errors_task(root, args) do
    File.cd!(root, fn ->
      Mix.shell(Mix.Shell.Process)
      Mix.Tasks.Surfex.Status.run(args)
    end)
  after
    Mix.shell(Mix.Shell.IO)
  end

  defp errors_output do
    receive do
      {:mix_shell, :info, [text]} -> text
    after
      0 -> flunk("no output")
    end
  end

  @tag verifies: ["scan-errors-collected", "scan-errors"]
  test "every unplaced contract fence in every file is reported in one run, sorted, once",
       %{tmp_dir: root} do
    File.cp_r!(@project, root)
    File.mkdir_p!(Path.join(root, "spec"))
    File.write!(Path.join(root, "spec/a.md"), spec_with_unplaced(3))
    File.write!(Path.join(root, "spec/b.md"), spec_with_unplaced(2))
    File.write!(Path.join(root, "spec/c.md"), spec_with_unplaced(3))
    File.write!(Path.join(root, ".surfex.exs"), ~s([sources: ["spec/*.md"], namespace: "MyApp"]))

    error = assert_raise Surfex.Scan.Errors, fn -> errors_task(root, []) end

    # Printed by mix as its message alone: no stack trace.
    assert error.mix == true
    [head | lines] = String.split(Exception.message(error), "\n")
    assert head =~ "8 scan errors"
    assert length(lines) == 8

    located = Enum.map(lines, fn line -> line |> String.split(":") |> Enum.take(2) end)

    assert Enum.map(located, &hd/1) ==
             List.duplicate("spec/a.md", 3) ++
               List.duplicate("spec/b.md", 2) ++ List.duplicate("spec/c.md", 3)

    assert located ==
             Enum.sort_by(located, fn [file, line] -> {file, String.to_integer(line)} end)

    assert Enum.all?(lines, &(&1 =~ "the contract signature names no module"))

    # The JSON report lists them in place of a status, and the run fails once.
    assert_raise Mix.Error, ~r/8 scan errors/, fn -> errors_task(root, ["--format", "json"]) end
    json = :json.decode(errors_output())
    assert json["failing"] == true
    assert length(json["scan_errors"]) == 8

    assert %{"file" => "spec/a.md", "line" => _, "message" => _} = hd(json["scan_errors"])
  end

  @tag verifies: ["scan-errors-collected", "scan-errors"]
  test "unreadable tags in every test and support file are reported with the spec's errors",
       %{tmp_dir: root} do
    File.cp_r!(@project, root)
    File.write!(Path.join(root, "spec.md"), spec_with_unplaced(1))
    File.mkdir_p!(Path.join(root, "test/support"))

    File.write!(Path.join(root, "test/a_test.exs"), """
    defmodule ATest do
      use ExUnit.Case
      @tag verifies: some_ids()
      test "a", do: :ok
    end
    """)

    File.write!(Path.join(root, "test/b_test.exs"), """
    defmodule BTest do
      use ExUnit.Case
      @moduletag deviation: 119
      test "b", do: :ok
    end
    """)

    File.write!(Path.join(root, "test/support/helper.ex"), """
    defmodule Helper do
      @tag verifies: [:not_a_string]
      def help, do: :ok
    end
    """)

    File.write!(
      Path.join(root, ".surfex.exs"),
      ~s([sources: ["spec.md"], tests: ["test/*_test.exs"], namespace: "MyApp"])
    )

    error = assert_raise Surfex.Scan.Errors, fn -> errors_task(root, []) end
    [_head | lines] = String.split(Exception.message(error), "\n")

    assert [
             "spec.md:" <> _,
             "test/a_test.exs:3: verifies: must be a string or a list of strings",
             "test/b_test.exs:3: deviation: must be a string",
             "test/support/helper.ex:2: verifies: must be a string or a list of strings"
           ] = lines

    # The library functions raise once, naming every error, one per line.
    spec_error = assert_raise ArgumentError, fn -> Markdown.records(root, ["spec.md"]) end
    assert spec_error.message =~ ~r/^spec\.md:\d+: the contract signature names no module/

    tests_error =
      assert_raise ArgumentError, fn -> Scan.ExUnit.records(root, ["test/*_test.exs"]) end

    assert tests_error.message ==
             "test/a_test.exs:3: verifies: must be a string or a list of strings\n" <>
               "test/b_test.exs:3: deviation: must be a string\n" <>
               "test/support/helper.ex:2: verifies: must be a string or a list of strings"

    text = File.read!(Path.join(root, "test/a_test.exs"))

    assert_raise ArgumentError, ~r/^test\/a_test.exs:3: verifies:/, fn ->
      Scan.ExUnit.tests(text, "test/a_test.exs")
    end
  end

  @tag verifies: ["scan-errors-continue", "scan-errors"]
  test "the scan reads past each error to the end of the text" do
    text = """
    # Feed

    <!-- surfex: a -->
    A paragraph.

    ## Again <!-- surfex: a -->

    <!-- surfex: class nope -->

    - <!-- surfex: r1 --> an item
      - <!-- surfex: r2 --> a nested rule

    ## After

    Still read.

    ```test:open-hint
    never closed
    """

    {scans, errors} = Markdown.read(text, "spec.md")

    assert Enum.map(errors, &{&1.line, &1.message}) == [
             {6, "spec.md#a is already the id of line 4"},
             {8, "class nope isn't declared in spec_classes:"},
             {11, "rule r1 (line 10) can't hold another rule"},
             {17, "test hint open-hint is never closed"}
           ]

    # What follows each error is read as before.
    assert "spec.md#Feed/After" in Enum.map(scans, & &1.id)
    assert "spec.md#r1" in Enum.map(scans, & &1.id)

    # The one-text function raises once, naming every error, one per line.
    error = assert_raise ArgumentError, fn -> Markdown.sections(text, "spec.md") end
    assert length(String.split(error.message, "\n")) == 4
    assert error.message =~ "spec.md:6: spec.md#a is already the id of line 4\nspec.md:8:"
  end
end
