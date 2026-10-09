defmodule Surfex.DeterminismTest do
  # #151: an output is a function of what it reports, never of the order its inputs came
  # in. The log's lines arrive in whatever order a union merge left them, and scans in
  # whatever order the file system listed them; a golden that reordered with them would
  # churn, and churn teaches people to regenerate without reading.
  use ExUnit.Case, async: true
  @moduletag verifies: "deterministic-output"

  alias Surfex.{Completeness, Record, Status, Suggest}
  alias Surfex.Status.{Config, Report}

  # Surfex's own log and scans: every report from them, in two orders, is byte-identical.
  # Each order's outputs are computed once.
  defp outputs({scans, entries}, config, options) do
    status = Status.derive(scans, entries, Config.require!(config), options)
    report = Completeness.report(status)

    %{
      status: {Report.text(status), Report.json(status), Report.golden(status)},
      completeness:
        {Completeness.text(report), Completeness.json(report),
         Completeness.golden(report, "COMPLETENESS.md")},
      history: Record.history(entries, "spec.md#recording")
    }
  end

  setup_all do
    root = File.cwd!()
    config = Config.read!(Path.join(root, ".surfex.exs"))
    {scans, options} = Config.load(config, root, "Surfex")
    entries = Surfex.Log.load(root)

    :rand.seed(:exsss, {151, 151, 151})
    shuffled = {Enum.shuffle(scans), entries |> Enum.shuffle() |> Enum.reverse()}

    [first, second] =
      [{scans, entries}, shuffled]
      |> Task.async_stream(&outputs(&1, config, options), timeout: :infinity)
      |> Enum.map(fn {:ok, outputs} -> outputs end)

    %{first: first, second: second}
  end

  for output <- [:status, :completeness, :history] do
    test "#{output} doesn't depend on the order of the scans or the log's lines", %{
      first: first,
      second: second
    } do
      assert first[unquote(output)] == second[unquote(output)]
    end
  end

  # Suggestions need a corpus that has some: on a log where everything is related they're
  # all empty, and an empty list is the same in any order. The reference fixture, with
  # tests that call its code and declare one of its units, always suggests plenty.
  @reference Path.expand("../fixtures/reference", __DIR__)

  test "suggestions don't depend on the order of the scans" do
    {items, _} = Code.eval_file(Path.join(@reference, "items.exs"))
    items = Enum.map(items, &struct!(Surfex.Item, &1))
    {config, _} = Code.eval_file(Path.join(@reference, "surfex.exs"))
    profile = Config.profile!(config, nil)
    root = Path.join(@reference, "sources")
    spec = Surfex.Scan.Markdown.records(root, ["spec/**/*.md", "notes/**/*.md"])
    code = Surfex.Scan.code(items)
    code_ids = code |> Enum.map(& &1.id) |> Enum.sort()
    unit = hd(spec).id

    tests =
      for n <- 1..4 do
        %Surfex.Scan{
          kind: :test,
          id: "T: case #{n}",
          hash: "t#{n}",
          location: %{file: "test/t_test.exs", lines: {n, n}},
          calls: code_ids |> Enum.drop(n) |> Enum.take(3),
          declares: [{:verifies, unit}]
        }
      end

    scans = spec ++ code ++ tests
    :rand.seed(:exsss, {167, 167, 167})
    first = Suggest.all(profile, items, scans, [], root)
    second = Suggest.all(profile, items, scans |> Enum.shuffle() |> Enum.reverse(), [], root)

    assert length(first.tests) >= 10 and length(first.verifies) == 4
    assert first == second
  end
end
