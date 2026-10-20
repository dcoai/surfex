defmodule Surfex.EstablishedCitationsTaskTest do
  # #321: mix surfex.suggest says how many prose citations an established log didn't
  # propose, and says nothing while there are none (§15.4). The task reads the working
  # directory and the Mix shell, which are global.
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    File.cp_r!(Path.expand("../fixtures/elixir_project", __DIR__), root)

    File.write!(Path.join(root, "spec.md"), """
    # Carts
    <!-- surfex: carts -->

    A cart totals its lines with `MyApp.Cart.total`.

    # Lines
    <!-- surfex: lines -->

    A line is made by `MyApp.Cart.Line.new/1`.
    """)

    File.write!(Path.join(root, ".surfex.exs"), ~s([sources: ["spec.md"]]))
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    :ok
  end

  defp ect_suggest(root) do
    File.cd!(root, fn -> Mix.Tasks.Surfex.Suggest.run([]) end)
    ect_drain()
  end

  defp ect_drain(acc \\ []) do
    receive do
      {:mix_shell, :info, [text]} -> ect_drain([text | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @tag verifies: ["withheld-count", "established-citations"]
  test "the count line appears once the log is established, and only then", %{tmp_dir: root} do
    File.cd!(root, fn ->
      Mix.Tasks.Surfex.Log.run(["--init"])

      Mix.Tasks.Surfex.Relate.run([
        "spec.md#lines",
        "MyApp.Cart.Line.new/1",
        "--type",
        "implements"
      ])
    end)

    # Proposed only: not established, so the prose span in Carts proposes as before.
    lines = ect_suggest(root)
    assert Enum.any?(lines, &(&1 =~ "implements  spec.md#carts ↔ MyApp.Cart.total/0"))
    refute Enum.any?(lines, &(&1 =~ "not proposed"))

    # Reviewed: established. The span proposes nothing, and one line says so.
    File.cd!(root, fn ->
      entries = Surfex.Log.load(root)
      [proposed] = Enum.filter(entries, &(&1.type == :implements))

      Surfex.Log.append(root, [
        Surfex.Log.Entry.new!(
          at: "2026-10-20T12:00:00Z",
          op: :relate,
          type: :implements,
          basis: :review,
          parents: [proposed.id],
          ends: proposed.ends,
          note: "reviewed"
        )
      ])
    end)

    lines = ect_suggest(root)
    refute Enum.any?(lines, &(&1 =~ "spec.md#carts ↔"))

    assert "1 prose citation not proposed (log established: relate the claim, not the sentence)" in lines
  end
end
