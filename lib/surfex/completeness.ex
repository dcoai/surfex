defmodule Surfex.Completeness do
  @moduledoc """
  How much of a project is covered (§20): which spec units, tests and code miss a relation
  they need, and a score per kind and overall. A pure function of a status, so of the scans
  and the log. Complete means validated (§18), not asserted.

    * **A spec unit** with text of its own is complete when a test verifies it, or a unit
      inside it, by a current, validated relation, and every `implements` relation to it
      is current and validated. A unit no code implements needs its test alone.
    * **A test** is complete when it verifies a unit by a current, validated relation and
      exercises code; verifying only units no code implements, its `verifies` is enough.
    * **Code** is complete when it implements a unit by a current, validated relation, or
      is excused by a current one; and, when implemented, a verifying test exercises it.
  """

  alias Surfex.{Golden, Scan}
  alias Surfex.Scan.Markdown

  @kinds [spec: "spec units", test: "tests", code: "code"]

  @type score :: %{complete: non_neg_integer, total: non_neg_integer, percent: float}
  @type item :: %{
          kind: :spec | :test | :code,
          id: String.t(),
          missing: [atom],
          location: map | nil
        }
  @type t :: %{
          scores: %{spec: score, test: score, code: score, overall: score},
          incomplete: [item]
        }

  @doc "The completeness report of a status."
  @spec report(Surfex.Status.t()) :: t
  def report(status) do
    live = for r <- status.relations, r.state != :retired, do: r
    within = for {{:spec, id}, %Scan{within: w}} <- status.scans, w != nil, into: %{}, do: {id, w}
    scans = status.scans |> Map.values() |> Enum.sort_by(&{&1.kind, &1.id})

    judged =
      for %Scan{kind: kind} = scan <- scans,
          kind in [:spec, :test, :code],
          kind != :spec or not Markdown.empty?(scan),
          do: {kind, scan, missing(kind, scan, live, within, status)}

    scores =
      for {kind, _label} <- @kinds, into: %{} do
        items = for {^kind, _scan, missing} <- judged, do: missing
        {kind, score(Enum.count(items, &(&1 == [])), length(items))}
      end

    overall = score(Enum.count(judged, &(elem(&1, 2) == [])), length(judged))

    incomplete =
      for {kind, scan, [_ | _] = missing} <- judged,
          do: %{kind: kind, id: scan.id, missing: missing, location: scan.location}

    %{scores: Map.put(scores, :overall, overall), incomplete: incomplete}
  end

  defp score(complete, total) do
    percent = if total == 0, do: 100.0, else: Float.round(complete * 100 / total, 1)
    %{complete: complete, total: total, percent: percent}
  end

  # ── What each kind misses ────────────────────────────────────────────────

  defp missing(kind, scan, live, within, status) do
    key = {kind, scan.id}
    touching = Enum.filter(live, &(key in ends(&1)))
    if touching == [], do: [:no_relation], else: lacks(kind, scan, touching, live, within, status)
  end

  defp lacks(:spec, scan, touching, live, within, status) do
    verified =
      Enum.any?(live, fn
        %{relation: {:verifies, {:test, _}, {:spec, unit}}} = r ->
          validated?(status, r) and inside?(unit, scan.id, within)

        _ ->
          false
      end)

    implements = for %{relation: {:implements, _, _}} = r <- touching, do: r

    if(verified, do: [], else: [:no_test]) ++
      if Enum.all?(implements, &validated?(status, &1)), do: [], else: [:unvalidated]
  end

  defp lacks(:test, _scan, touching, live, within, status) do
    verifies =
      for %{relation: {:verifies, {:test, _}, _}} = r <- touching, validated?(status, r), do: r

    exercises = Enum.any?(touching, &match?(%{relation: {:tests, _, _}, state: :current}, &1))

    code_less =
      verifies != [] and
        Enum.all?(verifies, fn %{relation: {_, _, {:spec, unit}}} ->
          not implemented?(unit, live, within)
        end)

    if(verifies == [], do: [:verifies_nothing], else: []) ++
      if exercises or code_less, do: [], else: [:exercises_nothing]
  end

  defp lacks(:code, scan, touching, _live, _within, status) do
    implements = for %{relation: {:implements, _, _}} = r <- touching, do: r
    excused = Enum.any?(touching, &match?(%{relation: {:excuses, _, _}, state: :current}, &1))

    cond do
      implements == [] and not excused ->
        [:not_described]

      implements == [] ->
        []

      true ->
        untested =
          Enum.any?(status.triangle, &(&1.gap == :code_untested and &1.code == scan.id))

        if(Enum.all?(implements, &validated?(status, &1)), do: [], else: [:unvalidated]) ++
          if untested, do: [:untested], else: []
    end
  end

  defp ends(%{relation: {_type, a, b}}), do: [a, b]

  # Validated now, as status judges it: a baseline that still holds counts (§18.1).
  defp validated?(status, relation), do: Surfex.Status.validated?(status, relation)

  # A unit's code is its own implements, or its enclosing unit's: a hint's code is its
  # section's.
  defp implemented?(unit, live, within) do
    Enum.any?(live, &match?(%{relation: {:implements, _, {:spec, ^unit}}}, &1)) or
      case Map.fetch(within, unit) do
        {:ok, parent} -> implemented?(parent, live, within)
        :error -> false
      end
  end

  defp inside?(unit, unit, _within), do: true

  defp inside?(unit, target, within) do
    case Map.fetch(within, unit) do
      {:ok, parent} -> inside?(parent, target, within)
      :error -> false
    end
  end

  # ── Reports ─────────────────────────────────────────────────────────────

  @doc "The report as text: the scores, then each incomplete item, what it lacks and where."
  @spec text(t) :: String.t()
  def text(report) do
    %{scores: s, incomplete: incomplete} = report

    lines =
      for {kind, label} <- @kinds,
          do: "  #{label}: #{percent(s[kind])}\n"

    items =
      if incomplete == [],
        do: [],
        else: ["\nIncomplete:\n" | Enum.map(incomplete, &["  ", item_text(&1), "\n"])]

    IO.iodata_to_binary(["completeness: #{percent(s.overall)}\n", lines, items])
  end

  defp percent(%{complete: c, total: t, percent: p}), do: "#{p}% (#{c}/#{t})"

  defp item_text(i), do: "#{i.kind} #{i.id}#{at(i.location)}: #{Enum.join(i.missing, ", ")}"

  defp at(%{file: file, lines: {first, last}}), do: " (#{file}:#{first}-#{last})"
  defp at(%{file: file}), do: " (#{file})"
  defp at(nil), do: ""

  @doc "The report as JSON, the work list for an agent."
  @spec json(t) :: String.t()
  def json(report) do
    scores =
      Map.new(report.scores, fn {kind, s} ->
        {Atom.to_string(kind),
         %{"complete" => s.complete, "total" => s.total, "percent" => s.percent}}
      end)

    incomplete =
      Enum.map(report.incomplete, fn i ->
        %{
          "kind" => Atom.to_string(i.kind),
          "id" => i.id,
          "missing" => Enum.map(i.missing, &Atom.to_string/1),
          "location" => location_json(i.location)
        }
      end)

    %{"scores" => scores, "incomplete" => incomplete} |> :json.encode() |> IO.iodata_to_binary()
  end

  defp location_json(%{file: file, lines: {first, last}}),
    do: %{"file" => file, "lines" => [first, last]}

  defp location_json(%{file: file}), do: %{"file" => file, "lines" => :null}
  defp location_json(nil), do: :null

  @doc """
  The report as a golden (`COMPLETENESS.md` by default, §10.3): the scores and every
  incomplete item, with no hashes and no times.
  """
  @spec golden(t, String.t()) :: Golden.spec()
  def golden(report, output) do
    %{scores: s} = report

    %{
      name: Path.basename(output),
      purpose: "How much of the spec, the tests and the code is covered, and what isn't.",
      task: "surfex.goldens",
      gate: "completeness-drift",
      hardness: :hard,
      stats: [
        Golden.stat(
          "#{s.overall.total} items",
          [{"complete", s.overall.complete}, {"score", "#{s.overall.percent}%"}] ++
            for({kind, label} <- @kinds, do: {label, "#{s[kind].complete}/#{s[kind].total}"})
        )
      ],
      columns: ["Item", "Missing"],
      rows:
        for i <- report.incomplete do
          %{"Item" => {:code, "#{i.kind} #{i.id}"}, "Missing" => Enum.join(i.missing, ", ")}
        end
    }
  end

  @doc "Whether the report's overall score is below `min` (none when `min` is `nil`)."
  @spec below?(t, number | nil) :: boolean
  def below?(_report, nil), do: false
  def below?(report, min), do: report.scores.overall.percent < min
end
