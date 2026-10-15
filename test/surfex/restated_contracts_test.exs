defmodule Surfex.RestatedContractsTest do
  # §13.10: a contract stated differently in several spec files is listed, never failing
  # (#270).
  use ExUnit.Case, async: true

  alias Surfex.Scan.Markdown
  alias Surfex.Status
  alias Surfex.Status.Report

  # The section's own prose says what its hint does, so each test verifies both.
  @moduletag verifies: ["restated-listed", "restated-contracts"]

  defp fence(module, body), do: "# `#{module}`\n\n```elixir contract\n#{body}```\n"

  defp scans(files) do
    Enum.flat_map(files, fn {file, text} -> Markdown.sections(text, file, []) end)
  end

  defp restated(files), do: Status.derive(scans(files), []).restated

  test "one contract stated differently in two files is listed with both units, and doesn't fail" do
    status =
      Status.derive(
        scans([
          {"spec/16-context.md", fence("App.Context", "@spec apply(t, [{atom, term}]) :: t\n")},
          {"spec/13-api.md", fence("App.Context", "@spec apply(t, list) :: t\n")}
        ]),
        []
      )

    assert status.restated == [
             %{
               contract: "App.Context.apply/2",
               units: [
                 "spec/13-api.md#App.Context.apply/2",
                 "spec/16-context.md#App.Context.apply/2"
               ]
             }
           ]

    refute Status.failing?(status)
  end

  test "the same statement, another module's function, or a callback beside a spec isn't listed" do
    same = fence("App.Context", "@spec apply(t, list) :: t\n")
    assert restated([{"a.md", same}, {"b.md", same}]) == []

    # Only whitespace differs: the version collapses it.
    reflowed = fence("App.Context", "@spec apply(t,   list) ::\n        t\n")
    assert restated([{"a.md", same}, {"b.md", reflowed}]) == []

    other = fence("App.Api", "@spec apply(t, map) :: t\n")
    assert restated([{"a.md", same}, {"b.md", other}]) == []

    callback = fence("App.Context", "@callback apply(t, map) :: t\n")
    assert restated([{"a.md", same}, {"b.md", callback}]) == []
  end

  test "three files, two alike, list all three units" do
    one = fence("M", "@spec f(t) :: t\n")
    two = fence("M", "@spec f(t) :: t | nil\n")

    assert [%{contract: "M.f/1", units: ["a.md#M.f/1", "b.md#M.f/1", "c.md#M.f/1"]}] =
             restated([{"a.md", one}, {"b.md", one}, {"c.md", two}])
  end

  test "text, JSON and golden show the list only where it has an entry" do
    differ = [
      {"a.md", fence("M", "@spec f(t) :: t\n")},
      {"b.md", fence("M", "@spec f(t) :: :ok\n")}
    ]

    status = Status.derive(scans(differ), [])

    assert Report.text(status) =~
             "Restated (a contract stated differently in several files):\n  contract M.f/1: a.md#M.f/1, b.md#M.f/1\n"

    assert JSON.decode!(Report.json(status))["restated"] == [
             %{"contract" => "M.f/1", "units" => ["a.md#M.f/1", "b.md#M.f/1"]}
           ]

    golden = status |> Report.golden("RELATIONS.md") |> Surfex.Golden.render()
    assert golden =~ "restated contracts 1"
    assert golden =~ "`contract M.f/1`"

    plain = Status.derive(scans([{"a.md", fence("M", "@spec f(t) :: t\n")}]), [])
    refute Report.text(plain) =~ "Restated"
    assert JSON.decode!(Report.json(plain))["restated"] == []
    refute plain |> Report.golden("RELATIONS.md") |> Surfex.Golden.render() =~ "restated"
  end
end
