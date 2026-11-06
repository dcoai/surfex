defmodule Surfex.DispatchFormsTest do
  # #290, #377: a behaviour-plus-registry, and a module handed to a function that calls it back,
  # are common shapes no call in the source states.
  use ExUnit.Case, async: true
  @moduletag :tmp_dir

  alias Surfex.{Scan, Status}
  alias Surfex.Status.Config

  @lib """
  defmodule Rpt do
    @moduledoc "What a report does."
    @doc "Its rows."
    @callback rows(term) :: list
    @doc "Its name."
    @callback title() :: String.t()
  end

  defmodule Rpt.Sales do
    @moduledoc "One report."
    @behaviour Rpt
    @doc "Rows."
    def rows(s), do: [s]
    @doc "Title."
    def title, do: "sales"
    @doc "No callback."
    def extra, do: :ok
  end

  defmodule Rpt.Stock do
    @moduledoc "Another."
    @behaviour Rpt
    @impl true
    def rows(s), do: Rpt.Stock.Cells.of(s)
    @impl true
    def title, do: "stock"
  end

  defmodule Rpt.Stock.Cells do
    @moduledoc "What it calls."
    @doc "Cells."
    def of(s), do: [s]
  end

  defmodule Rpt.Plain do
    @moduledoc "Listed, implementing nothing."
    @doc "Something."
    def other, do: :ok
  end

  defmodule Billing do
    @moduledoc "Runs each report."
    @reports [Rpt.Sales, Rpt.Stock]
    @doc "Runs."
    def run(selection), do: Enum.map(reports(), & &1.rows(selection))
    @doc "From an attribute."
    def reports, do: @reports
    @doc "Runs the listed literal."
    def run_listed(s), do: Enum.map(listed(), & &1.rows(s))
    @doc "A literal list, one implementing nothing, one unscanned."
    def listed, do: [Rpt.Sales, Rpt.Plain, Elsewhere]
    @doc "Runs a computed list."
    def run_computed(s), do: Enum.map(computed(), & &1.rows(s))
    @doc "Not literal."
    def computed, do: Enum.reverse([Rpt.Sales])
  end

  defmodule Http do
    @moduledoc "Pages through, calling back the pager handed in."
    @doc "Reads."
    def read(url, pager), do: pager.rows(url)
  end
  """

  @tests """
  defmodule BillingTest do
    use ExUnit.Case
    test "through the registry", do: assert(Billing.run(:all))
    test "through the listed", do: assert(Billing.run_listed(:all))
    test "through the computed", do: assert(Billing.run_computed(:all))
    test "a module as a value", do: assert(Http.read("u", Rpt.Stock))
    test "a module piped to", do: assert("u" |> Http.read(Rpt.Sales))
    test "a value that isn't literal" do
      pager = Rpt.Stock
      assert Http.read("u", pager)
    end
    test "a literal that implements nothing", do: assert(Http.read("u", Rpt.Plain))
  end
  """

  defp world(root, dispatch) do
    for {path, text} <- [
          {"lib/x.ex", @lib},
          {"test/x_test.exs", @tests},
          {"spec.md", "# S\n\nText.\n"}
        ] do
      File.mkdir_p!(Path.dirname(Path.join(root, path)))
      File.write!(Path.join(root, path), text)
    end

    config = [sources: ["spec.md"], tests: ["test/*_test.exs"], dispatch: dispatch]
    {config, Config.scans(config, root)}
  end

  defp reach(root, dispatch, test) do
    {_, scans} = world(root, dispatch)
    Scan.reach(scans)["BillingTest: #{test}"]
  end

  @registry {Billing, :run, 1, registry: {Billing, :reports, 0}}

  @tag verifies: "dispatch-registry"
  test "a call to a registry dispatcher reaches each listed module's callbacks", %{tmp_dir: root} do
    reached = reach(root, [@registry], "through the registry")

    for id <- ~w(Rpt.Sales Rpt.Sales.rows/1 Rpt.Sales.title/0 Rpt.Stock Rpt.Stock.Cells.of/1) do
      assert id in reached, "#{id} in #{inspect(reached)}"
    end

    refute "Rpt.Sales.extra/0" in reached

    # Without the declaration it reaches none of them.
    refute "Rpt.Sales.rows/1" in reach(root, [], "through the registry")
  end

  @tag verifies: "dispatch-registry"
  test "callback: narrows to the functions of that name", %{tmp_dir: root} do
    reached =
      reach(
        root,
        [{Billing, :run, 1, registry: {Billing, :reports, 0}, callback: :rows}],
        "through the registry"
      )

    assert "Rpt.Sales.rows/1" in reached
    refute "Rpt.Sales.title/0" in reached
  end

  @tag verifies: "dispatch-registry"
  test "what can't be read is listed: unresolved, unscanned, and an undefined catalogue refused",
       %{
         tmp_dir: root
       } do
    {_, scans} =
      world(root, [
        {Billing, :run_listed, 1, registry: {Billing, :listed, 0}},
        {Billing, :run_computed, 1, registry: {Billing, :computed, 0}}
      ])

    %{dispatch: dispatch} = status = Status.derive(scans, [], [], [])

    assert %{unresolved: true, targets: []} =
             Enum.find(dispatch, &(&1.dispatcher == "Billing.run_computed/1"))

    assert %{unresolved: false, unscanned: ["Elsewhere", "Rpt.Plain"], targets: targets} =
             Enum.find(dispatch, &(&1.dispatcher == "Billing.run_listed/1"))

    assert "Rpt.Sales.rows/1" in targets
    refute Status.failing?(status)

    assert_raise ArgumentError, ~r/Billing.nowhere\/0 isn't a function/, fn ->
      world(root, [{Billing, :run, 1, registry: {Billing, :nowhere, 0}}])
    end
  end

  @tag verifies: "dispatch-module-arg"
  test "a literal module at the declared argument reaches its callbacks", %{tmp_dir: root} do
    declared = [{Http, :read, 2, module_arg: 2}]
    reached = reach(root, declared, "a module as a value")

    for id <- ~w(Rpt.Stock Rpt.Stock.Cells.of/1), do: assert(id in reached)
    refute "Rpt.Sales.rows/1" in reached

    # A piped call counts its piped value as the first argument.
    assert "Rpt.Sales.rows/1" in reach(root, declared, "a module piped to")

    # Without the declaration a module named as a value is named, and its callbacks aren't called.
    refute "Rpt.Stock.Cells.of/1" in reach(root, [], "a module as a value")
  end

  @tag verifies: "dispatch-module-arg"
  test "anything else there reaches no callback", %{tmp_dir: root} do
    declared = [{Http, :read, 2, module_arg: 2}]

    refute "Rpt.Stock.Cells.of/1" in reach(root, declared, "a value that isn't literal")
    refute "Rpt.Plain.other/0" in reach(root, declared, "a literal that implements nothing")

    {_, scans} = world(root, declared)
    assert [%{unresolved: false, targets: targets}] = Status.derive(scans, [], [], []).dispatch
    assert "Rpt.Stock.rows/1" in targets
  end

  @tag verifies: "dispatch-module-arg"
  test "a malformed form is refused, naming what's expected", %{tmp_dir: _root} do
    for bad <- [
          {Http, :read, 2, module_arg: 3},
          {Http, :read, 2, module_arg: 0},
          {Http, :read, 2, module_arg: 1, registry: {Billing, :reports, 0}},
          {Http, :read, 2, callback: :rows},
          {Http, :read, 2, registry: :nope},
          {Http, :read, 2, module_arg: 1, callback: "rows"},
          {Http, :read, 2, surprise: 1}
        ] do
      assert_raise ArgumentError, ~r/dispatch:/, fn -> Config.dispatch!(dispatch: [bad]) end
    end

    assert Config.dispatch!(dispatch: [{Http, :read, 2}]) == ["Http.read/2"]
  end
end
