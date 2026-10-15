defmodule Surfex.DeviationConfirmTaskTest do
  # #255: mix surfex.confirm --evidence, with the real tasks and the real formatter, holds
  # back an implements over a deviating unit and says so (§13.11).
  # The tasks read the working directory, which is global.
  use ExUnit.Case, async: false

  @moduletag :tmp_dir
  @project Path.expand("../fixtures/elixir_project", __DIR__)
  @function "MyApp.Cart.total/0"

  @spec_text """
  # Totals {#totals}

  A cart's total.

  ## Discounts {#discounts}

  A cart's discount is taken off its total.

  ```test discount-test
  a discount is taken off the total
  ```
  """

  # The plain test (line 5) verifies the hint and the top section; the deviation test
  # (line 11) declares the code doesn't meet the hint yet.
  @tests """
  defmodule MyApp.CartTest do
    use ExUnit.Case

    @tag verifies: ["discount-test", "totals"]
    test "an empty cart totals" do
      assert MyApp.Cart.total() == 1
    end

    @tag verifies: "discount-test", deviation: "#119"
    @tag skip: "#119"
    test "a discount is taken off" do
      assert MyApp.Cart.total() == 0
    end
  end
  """

  setup %{tmp_dir: root} do
    File.cp_r!(@project, root)
    File.write!(Path.join(root, "spec.md"), @spec_text)
    File.mkdir_p!(Path.join(root, "test"))
    File.write!(Path.join(root, "test/cart_test.exs"), @tests)
    task(root, Mix.Tasks.Surfex.Log, ["--init"])
    %{root: root}
  end

  defp task(root, module, args) do
    File.cd!(root, fn ->
      Mix.shell(Mix.Shell.Process)
      module.run(args)
    end)
  after
    Mix.shell(Mix.Shell.IO)
  end

  defp drain(acc \\ []) do
    receive do
      {:mix_shell, :info, [text]} -> drain([text | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # One run of the plain test, as ExUnit reports it to the formatter.
  defp run_test(root, state) do
    {:ok, pid} = GenServer.start_link(Surfex.ExUnitFormatter, surfex_root: root)
    GenServer.cast(pid, {:suite_started, []})

    test = %ExUnit.Test{
      name: :t,
      module: MyApp.CartTest,
      state: state,
      tags: %{file: Path.join(root, "test/cart_test.exs"), line: 5}
    }

    GenServer.cast(pid, {:test_finished, test})
    GenServer.cast(pid, {:suite_finished, %{}})
    GenServer.stop(pid)
  end

  # Both sections' implements proposed, the verifies proposed; the plain test red, the code
  # fixed, green; then confirm by evidence.
  defp confirm(root, config) do
    File.write!(Path.join(root, ".surfex.exs"), config)

    for unit <- ["spec.md#totals", "spec.md#discounts"],
        do: task(root, Mix.Tasks.Surfex.Relate, [@function, unit, "--type", "implements"])

    task(root, Mix.Tasks.Surfex.Suggest, ["--accept", "--note", "the tests' declarations"])
    run_test(root, {:failed, []})

    path = Path.join(root, "lib/my_app/cart.ex")
    File.write!(path, String.replace(File.read!(path), "helper(0)", "helper(1)"))

    run_test(root, nil)
    drain()
    task(root, Mix.Tasks.Surfex.Confirm, ["--evidence"])
    drain()
  end

  defp held(unit),
    do: "held back by a deviation: implements  code #{@function} ↔ spec #{unit} (deviates: #119)"

  @tag verifies: ["deviation-holds-back", "deviation-holds"]
  test "confirm --evidence lists the held implements, the section above too", %{root: root} do
    lines = confirm(root, ~s([sources: ["spec.md"], tests: ["test/*_test.exs"]]))

    assert held("spec.md#discounts") in lines
    assert held("spec.md#totals") in lines
    refute Enum.any?(lines, &(&1 =~ "recorded relate implements"))
    assert Enum.any?(lines, &(&1 =~ "recorded relate verifies"))
  end
end
