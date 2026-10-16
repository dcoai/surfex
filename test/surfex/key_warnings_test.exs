defmodule Surfex.KeyWarningsTest do
  # #286: a marked table's key that holds an unspaced `/`, or that is a code span followed
  # by prose, is probably a mistake in how the row is written: a spec-shape warning on the
  # row (§11.12), never a re-key and never a failure.
  use ExUnit.Case, async: true

  alias Surfex.Scan
  alias Surfex.Scan.Markdown
  alias Surfex.Status
  alias Surfex.Status.Report

  describe "key warnings" do
    @describetag verifies: ["key-warnings", "spec-shape"]

    defp table(rows, marker \\ "<!-- surfex: table t -->", header \\ "| K | V |") do
      "# S\n\n#{marker}\n#{header}\n|---|---|\n" <> Enum.join(rows, "\n") <> "\n"
    end

    defp warned(text) do
      for %{role: :row} = u <- Markdown.sections(text, "s.md"), w <- u.warnings do
        {u.id, w.kind, w.line, w.message}
      end
    end

    test "an unspaced / outside code spans is slash_key, and the row still resolves" do
      text =
        table(["| HTML/D3 visualizer | x |", "| a / b | x |", "| `f/2` | x |", "| plain | x |"])

      assert [{"s.md#t/HTML/D3 visualizer", :slash_key, 6, message}] = warned(text)
      assert message =~ ~s(its key "HTML/D3 visualizer" holds a / outside a code span)
      assert message =~ "TABLE/KEY still resolves it"

      scans = Markdown.sections(text, "s.md")

      assert {:ok, %Scan{role: :row, id: "s.md#t/HTML/D3 visualizer"}} =
               Scan.resolve(Scan.resolver(scans), "s.md#t/HTML/D3 visualizer")

      # The spaced ` / ` is a list-shaped key (§11.2) and only that: no row is listed twice.
      status = Status.derive(scans, [])
      assert [%{row: %{id: "s.md#t/a / b"}}] = Status.list_keys(status)
    end

    test "a composite key's joining / isn't warned; a part's own / is" do
      text =
        table(
          ["| render | :width | x |", "| read/write | :mode | x |"],
          "<!-- surfex: table t key: [F, K] -->",
          "| F | K | V |"
        )
        |> String.replace("|---|---|", "|---|---|---|")

      assert [{"s.md#t/read/write/:mode", :slash_key, 7, _}] = warned(text)
    end

    test "a code span followed by prose is span_key, naming the span as the probable key" do
      text =
        table([
          "| `ack` (high 3 bytes of TCP ack) | x |",
          "| `seq` | x |",
          "| `a`, `b` | x |",
          "| `a` and `b` | x |",
          "| `x` then `y` | x |"
        ])

      assert [{"s.md#t/ack (high 3 bytes of TCP ack)", :span_key, 6, message}] = warned(text)
      assert message =~ ~s(the span alone, "ack", is probably the key)
    end

    test "the status lists both under Spec shape and in spec_warnings, and doesn't fail" do
      status =
        table(["| HTML/D3 visualizer | x |", "| `ack` (high 3 bytes) | x |"])
        |> Markdown.sections("s.md")
        |> Status.derive([])

      refute Status.failing?(status)

      text = Report.text(status)
      assert text =~ "Spec shape (warnings; none fails):"
      assert text =~ "Keys holding a /"
      assert text =~ "Keys that are a code span and prose"
      assert text =~ "(s.md:6)"
      assert text =~ "(s.md:7)"

      assert [
               %{"kind" => "slash_key", "line" => 6, "unit" => "s.md#t/HTML/D3 visualizer"},
               %{"kind" => "span_key", "line" => 7, "unit" => "s.md#t/ack (high 3 bytes)"}
             ] = status |> Report.json() |> :json.decode() |> Map.fetch!("spec_warnings")
    end
  end
end
