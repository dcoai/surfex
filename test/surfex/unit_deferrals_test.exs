defmodule Surfex.UnitDeferralsTest do
  # #284 (for #274): a deferral may cite the spec unit that records the decision instead of
  # an issue, pinned to the version its author judged, and goes stale when that unit
  # changes (§13.13).
  use ExUnit.Case, async: true

  alias Surfex.Log.Entry
  alias Surfex.Scan
  alias Surfex.Scan.Markdown
  alias Surfex.Status
  alias Surfex.Status.{Config, Report}

  @decisions """
  # Deferred past v1
  <!-- surfex: deferred-table -->

  | Item | Why |
  |---|---|
  | Views | easy to make unsound |

  # Elsewhere

  Text.
  """

  defp model(pin) do
    """
    # Views
    <!-- surfex: views -->
    <!-- surfex: deferred spec/06-decisions.md#deferred-table#{pin}: past v1 -->

    Views later.

    # Gate
    <!-- surfex: gate -->

    <!-- surfex: gate-block -->
    <!-- surfex: deferred #13 -->
    The gate block.
    <!-- /surfex -->
    """
  end

  defp write!(root, model, decisions \\ @decisions) do
    File.mkdir_p!(Path.join(root, "spec"))
    File.write!(Path.join(root, "spec/04-model.md"), model)
    File.write!(Path.join(root, "spec/06-decisions.md"), decisions)
  end

  defp records(root, opts \\ []), do: Markdown.records(root, ["spec/*.md"], [], opts)

  defp unit(scans, id), do: Enum.find(scans, &(&1.id == id))

  defp version(scans), do: unit(scans, "spec/06-decisions.md#deferred-table").hash

  defp stale(status), do: Enum.map(status.stale_deferrals, &{&1.unit, &1.reason})

  defp derive(scans, entries \\ [], opts \\ []),
    do: Status.derive(scans, entries, [], opts)

  describe "a citation resolves when the spec is scanned" do
    @describetag :tmp_dir

    @tag verifies: ["unit-deferral-resolves", "unit-deferrals"]
    test "by full id, bare anchor or a unit_refs: form, with its pin and reason", %{
      tmp_dir: root
    } do
      write!(root, model("@0123abcd"))
      scans = records(root)

      assert unit(scans, "spec/04-model.md#views").deferred == %{
               ref: "spec/06-decisions.md#deferred-table",
               reason: "past v1",
               cites: "spec/06-decisions.md#deferred-table",
               pin: "0123abcd",
               line: 3
             }

      # An issue deferral's record is as it was.
      assert unit(scans, "spec/04-model.md#gate-block").deferred == %{ref: "#13", reason: nil}

      # The marker is no part of the deferred unit's version.
      plain = String.replace(model(""), ~r/<!-- surfex: deferred spec.*\n/, "")
      write!(root, plain)

      assert unit(records(root), "spec/04-model.md#views").hash ==
               unit(scans, "spec/04-model.md#views").hash

      # A bare anchor, with no pin and no reason.
      write!(
        root,
        String.replace(
          model(""),
          "spec/06-decisions.md#deferred-table: past v1",
          "deferred-table"
        )
      )

      bare = unit(records(root), "spec/04-model.md#views").deferred

      assert %{
               ref: "deferred-table",
               cites: "spec/06-decisions.md#deferred-table",
               pin: nil,
               reason: nil
             } = bare

      # The project's own citation form, with spaces in it.
      write!(
        root,
        String.replace(
          model("@0123abcd"),
          "spec/06-decisions.md#deferred-table",
          "spec/06 §deferred-table"
        )
      )

      # The project's scans pass its unit_refs: to the spec scan.
      formed =
        Config.scans(
          [sources: ["spec/*.md"], unit_refs: [~r/^spec\/(?<chapter>\d+) §(?<id>[a-z-]+)$/]],
          root
        )

      assert %{
               ref: "spec/06 §deferred-table",
               cites: "spec/06-decisions.md#deferred-table",
               pin: "0123abcd"
             } =
               unit(formed, "spec/04-model.md#views").deferred
    end

    @tag verifies: ["unit-deferral-resolves", "unit-deferrals"]
    test "one citing no unit, or several, raises naming the file and line", %{tmp_dir: root} do
      write!(
        root,
        String.replace(model(""), "spec/06-decisions.md#deferred-table", "no-such-unit")
      )

      error = assert_raise ArgumentError, fn -> records(root) end
      assert error.message =~ "spec/04-model.md:3:"
      assert error.message =~ "is no spec unit"

      twice = @decisions <> "\n# Again\n<!-- surfex: deferred-table -->\n\nAgain.\n"
      write!(root, String.replace(model(""), "spec/06-decisions.md#deferred-table", "views"))
      File.write!(Path.join(root, "spec/05-more.md"), "# More\n<!-- surfex: views -->\n\nMore.\n")
      error = assert_raise ArgumentError, fn -> records(root) end
      assert error.message =~ "spec/04-model.md:3:"
      assert error.message =~ "names several spec units"
      assert error.message =~ "spec/05-more.md#views"
      File.rm!(Path.join(root, "spec/05-more.md"))

      # A malformed pin is refused when the file is scanned.
      write!(root, model("@XYZ"), twice)
      error = assert_raise ArgumentError, fn -> records(root) end
      assert error.message =~ "spec/04-model.md:3:"
      assert error.message =~ "8 lowercase hex"
    end
  end

  describe "a citation goes stale when the cited unit changes" do
    @describetag :tmp_dir

    @tag verifies: ["unit-deferral-stale", "unit-deferrals"]
    test "pinned holds; edited is changed; no pin is unpinned; gone; built", %{tmp_dir: root} do
      write!(root, model(""))
      current = version(records(root))

      write!(root, model("@#{current}"))
      pinned = records(root)
      assert stale(derive(pinned)) == []
      refute Status.failing?(derive(pinned))

      # The decision text is edited: the deferral is judged again.
      write!(
        root,
        model("@#{current}"),
        String.replace(@decisions, "easy to make unsound", "unsound")
      )

      edited = records(root)
      changed = derive(edited)
      assert [%{reason: :changed, pin: ^current, version: now, line: 3}] = changed.stale_deferrals
      assert now == version(edited) and now != current
      assert Status.failing?(changed)

      text = Report.text(changed)
      assert text =~ "spec spec/04-model.md#views deferred by spec/06-decisions.md#deferred-table"
      assert text =~ "write spec/06-decisions.md#deferred-table@#{now} in the marker (line 3)"

      json = JSON.decode!(Report.json(changed))

      assert [%{"reason" => "changed", "pin" => ^current, "version" => ^now, "line" => 3}] =
               json["stale_deferrals"]

      assert [
               %{"ref" => "#13"} = issue,
               %{"cites" => "spec/06-decisions.md#deferred-table", "pin" => ^current}
             ] = json["deferred"]

      refute Map.has_key?(issue, "cites")

      # No pin: the status names the version to write.
      write!(root, model(""))
      unpinned = derive(records(root))
      assert stale(unpinned) == [{"spec/04-model.md#views", :unpinned}]
      assert Report.text(unpinned) =~ "pins no version"

      # The cited unit is gone (a hand-built scan; records/4 would raise first).
      gone = Enum.reject(pinned, &(&1.id == "spec/06-decisions.md#deferred-table"))
      assert stale(derive(gone)) == [{"spec/04-model.md#views", :gone}]

      # Built: the unit has its own evidence, whatever the pin.
      views = unit(pinned, "spec/04-model.md#views")

      t = %Scan{
        kind: :test,
        id: "T: views",
        hash: "t",
        declares: [{:verifies, "views"}],
        location: %{file: "test/v_test.exs", lines: {1, 2}}
      }

      verifies =
        Entry.new!(
          at: "2026-10-15T10:00:00Z",
          op: :relate,
          type: :verifies,
          basis: :review,
          by: "t",
          note: "checked",
          ends: [
            %{kind: :test, id: t.id, hash: t.hash},
            %{kind: :spec, id: views.id, hash: views.hash}
          ]
        )

      assert stale(derive(edited ++ [t], [verifies])) == [{"spec/04-model.md#views", :built}]

      # Issue deferrals are judged as before; a citation has no issue.
      issues = derive(pinned, [], issues: %{"#13" => :closed})
      assert stale(issues) == [{"spec/04-model.md#gate-block", :closed}]

      assert Enum.map(issues.deferred, &{&1.unit, &1.issue}) == [
               {"spec/04-model.md#gate-block", :closed},
               {"spec/04-model.md#views", nil}
             ]
    end

    @tag verifies: ["unit-deferral-stale", "unit-deferrals"]
    test "only issue references are asked of the tracker", %{tmp_dir: root} do
      write!(root, model(""))
      Surfex.Log.init(root)
      me = self()

      ask = fn refs ->
        send(me, {:asked, refs})
        Map.new(refs, &{&1, :open})
      end

      status =
        Config.status([sources: ["spec/*.md"]], root, "Surfex", issues: ask)

      assert_received {:asked, ["#13"]}
      assert stale(status) == [{"spec/04-model.md#views", :unpinned}]
    end
  end
end
