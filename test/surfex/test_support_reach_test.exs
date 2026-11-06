defmodule Surfex.TestSupportReachTest do
  # #290, #376: a test reading through a fixture helper verified a claim and "called none of its
  # code", so projects rewrote good tests to suit the tool.
  use ExUnit.Case, async: true
  @moduletag :tmp_dir

  alias Surfex.{Cite, Scan, Status}
  alias Surfex.Status.Config

  @config [sources: ["spec.md"], tests: ["test/*_test.exs"]]

  defp write(root, path, text) do
    full = Path.join(root, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, text)
  end

  defp project(root) do
    write(root, "lib/my_app/lock.ex", """
    defmodule MyApp.Lock do
      @moduledoc "Locks."
      @doc "Reads."
      def read(path), do: parse(path)
      @doc "Parses."
      def parse(path), do: path
      @doc "Never called."
      def unused, do: :ok
    end
    """)

    write(root, "test/support/lock_fixture.ex", """
    defmodule MyApp.LockFixture do
      @moduledoc "Fixtures."
      alias MyApp.Lock
      @type t :: term
      def write_and_read(path), do: helper(path)
      defp helper(path), do: MyApp.LockSteps.step(path) && Lock.read(path)
    end
    """)

    write(root, "test/support/lock_steps.ex", """
    defmodule MyApp.LockSteps do
      @moduledoc false
      # One module on, so reach is transitive, through a hidden module too.
      def step(path), do: MyApp.Lock.parse(path)
    end
    """)

    write(root, "test/lock_test.exs", """
    defmodule MyApp.LockTest do
      use ExUnit.Case
      alias MyApp.LockFixture

      @tag verifies: "lock-read"
      test "a lockfile through its fixture", do: assert(LockFixture.write_and_read("x"))
    end

    defmodule MyApp.ImportingTest do
      use ExUnit.Case
      import MyApp.LockFixture

      @tag verifies: "lock-read"
      test "a lockfile through an import", do: assert(write_and_read("x"))

      @tag verifies: "lock-read"
      test "no helper at all", do: assert(true)
    end
    """)

    write(root, "spec.md", """
    # Locks
    <!-- surfex: locks -->

    `MyApp.Lock.read/1` reads.

    `MyApp.LockFixture` writes one, by `MyApp.LockFixture.write_and_read/1` and
    `MyApp.LockFixture.write_and_read`, of type `MyApp.LockFixture.t/0`.

    `MyApp.LockFixtur` is misspelt, and `MyApp.LockFixture.nothing/0` isn't there.

    ```test:lock-read
    a lockfile reads
    ```
    """)
  end

  @tag verifies: "reach-test-support"
  test "a test reaches what a support helper calls, transitively", %{tmp_dir: root} do
    project(root)
    scans = Config.scans(@config, root)
    reach = Scan.reach(scans)

    expected = ["MyApp.Lock", "MyApp.Lock.parse/1", "MyApp.Lock.read/1"]
    assert Enum.sort(reach["MyApp.LockTest: a lockfile through its fixture"]) == expected
    assert Enum.sort(reach["MyApp.ImportingTest: a lockfile through an import"]) == expected
    assert reach["MyApp.ImportingTest: no helper at all"] == []
  end

  @tag verifies: "reach-test-support"
  test "support code is no item: never in New, unmet or completeness", %{tmp_dir: root} do
    project(root)
    scans = Config.scans(@config, root)

    refute Enum.any?(scans, &(&1.kind == :code and String.contains?(&1.id, "Fixture")))
    refute Enum.any?(scans, &(&1.kind == :code and String.contains?(&1.id, "LockSteps")))

    status = Status.derive(scans, [], [code: [:implements]], [])
    named = fn list -> Enum.map(list, &Map.get(&1, :scan, &1).id) end

    refute Enum.any?(named.(status.new), &String.contains?(&1, "Fixture"))
    refute Enum.any?(named.(status.unmet), &String.contains?(&1, "Fixture"))
    assert "MyApp.Lock.read/1" in named.(status.new)
  end

  @tag verifies: "reach-test-support"
  test "a file the tests: globs scan as tests isn't read as support", %{tmp_dir: root} do
    project(root)

    config = [sources: ["spec.md"], tests: ["test/*_test.exs", "test/support/*.ex"]]
    reach = config |> Config.scans(root) |> Scan.reach()

    assert reach["MyApp.LockTest: a lockfile through its fixture"] == []
  end

  @tag verifies: ["citation-test-support", "reach-test-support"]
  test "a citation of a support module, function or type is test support, not broken", %{
    tmp_dir: root
  } do
    project(root)
    items = Config.items(@config, root)
    profile = Config.profile!(@config, "MyApp", items)

    support = Scan.ExUnit.support_names(root, @config[:tests])
    all = Cite.citations(items, profile, root, support: support)
    status = Map.new(all, &{&1.span, &1.status})

    for span <- ~w(MyApp.LockFixture MyApp.LockFixture.write_and_read/1
                   MyApp.LockFixture.write_and_read MyApp.LockFixture.t/0) do
      assert status[span] == :test_support, "#{span}: #{status[span]}"
    end

    assert status["MyApp.Lock.read/1"] == :resolved
    assert status["MyApp.LockFixtur"] == :unresolved
    assert status["MyApp.LockFixture.nothing/0"] == :unresolved

    broken = Config.broken_citations(@config, items, root, "MyApp")

    assert Enum.sort(Enum.map(broken, & &1.span)) == [
             "MyApp.LockFixtur",
             "MyApp.LockFixture.nothing/0"
           ]
  end
end
