defmodule Surfex.Completeness do
  @moduledoc """
  How much of a project is covered (§20): which spec units, tests and code miss a relation
  they need, and a score per kind and overall. A pure function of a status, so of the scans
  and the log. Complete means validated (§18), not asserted.

    * **A spec unit** with text of its own is complete when a test verifies it, or a unit
      inside it, by a current, validated relation, and every `implements` relation to it
      is current and validated. A unit no code implements needs its test alone. A unit a
      test declares the code deviates from (`@tag deviation:`, `Surfex.Status`) is never
      complete: it misses `deviates`, with the references, whatever its basis.
    * **A test** is complete when it verifies a unit by a current, validated relation and
      exercises code; verifying only units no code implements, its `verifies` is enough.
    * **Code** is complete when it implements a unit by a current, validated relation, or
      is excused by a current one; and, when implemented, a verifying test exercises it.
      Code is one item per definition: a function's default-argument arities are judged
      together and counted once.

  Under `claim_grain: true` (§20.1) a spec unit is read as verification reads it
  (`Surfex.Status.verdict/2`): only claims are counted, and a claim is complete only with
  its own validated `verifies`. A contained claim misses `{:contained, units}`, naming the
  verified claims inside it.
  """

  alias Surfex.{Golden, Scan}
  alias Surfex.Scan.Markdown

  @kinds [spec: "spec units", test: "tests", code: "code"]

  @type score :: %{complete: non_neg_integer, total: non_neg_integer, percent: float}
  @type item :: %{
          kind: :spec | :test | :code,
          id: String.t(),
          missing: [atom | {:deviates, [String.t()]} | {:contained, [String.t()]}],
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

    # A deviating unit's code doesn't meet it, whatever validated its relations (§20).
    deviates =
      status.deviating
      |> Enum.group_by(& &1.spec, & &1.ref)
      |> Map.new(fn {unit, refs} -> {unit, [{:deviates, refs |> Enum.uniq() |> Enum.sort()}]} end)

    units_and_tests =
      for %Scan{kind: kind} = scan <- scans,
          kind in [:spec, :test],
          kind != :spec or counted?(scan, status),
          do:
            {kind, scan,
             missing(kind, scan, live, within, status) ++
               if(kind == :spec, do: Map.get(deviates, scan.id, []), else: [])}

    # Code is one item per definition (`Scan.definition/1`), as it is to `require:`, the
    # triangle and validate: a function's default-argument arities are judged together,
    # counted once, and listed under the first of their ids.
    code =
      for group <-
            scans
            |> Enum.filter(&(&1.kind == :code))
            |> Enum.group_by(&Scan.definition/1)
            |> Map.values(),
          group = Enum.sort_by(group, & &1.id),
          do: {:code, hd(group), missing_code(group, live, status)}

    judged = Enum.sort_by(units_and_tests ++ code, fn {kind, scan, _} -> {kind, scan.id} end)

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
    # At claim grain only the claim's own evidence completes it (§20.1); before it, a
    # unit inside it does too.
    verifies? =
      if status.policy.claim_grain,
        do: &(&1 == scan.id),
        else: &inside?(&1, scan.id, within)

    verified =
      Enum.any?(live, fn
        %{relation: {:verifies, {kind, _}, {:spec, unit}}} = r when kind in [:test, :check] ->
          validated?(status, r) and verifies?.(unit)

        _ ->
          false
      end)

    implements = for %{relation: {:implements, _, _}} = r <- touching, do: r

    if(verified, do: [], else: [untested(scan, status)]) ++
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

  # Why a unit lacks its test: at claim grain, a contained claim names the verified claims
  # inside it (§20.1).
  defp untested(scan, %{policy: %{claim_grain: true}} = status) do
    case Enum.find(status.contained, &(&1.unit == scan.id)) do
      nil -> :no_test
      %{inside: inside} -> {:contained, inside}
    end
  end

  defp untested(_scan, _status), do: :no_test

  # Which spec units are counted: those with text of their own; at claim grain, the claims
  # (§20.1), so a marked table, whose rows are its claims, isn't either.
  defp counted?(scan, %{policy: %{claim_grain: true}} = status),
    do: Surfex.Status.verdict(status, scan.id) in [:verified, :contained, :unverified]

  defp counted?(scan, _status), do: not Markdown.empty?(scan)

  defp missing_code(group, live, status) do
    keys = for s <- group, do: {:code, s.id}
    ids = for s <- group, do: s.id
    touching = Enum.filter(live, fn r -> Enum.any?(ends(r), &(&1 in keys)) end)
    if touching == [], do: [:no_relation], else: lacks_code(ids, touching, status)
  end

  defp lacks_code(ids, touching, status) do
    implements = for %{relation: {:implements, _, _}} = r <- touching, do: r
    excused = Enum.any?(touching, &match?(%{relation: {:excuses, _, _}, state: :current}, &1))

    cond do
      implements == [] and not excused ->
        [:not_described]

      implements == [] ->
        []

      true ->
        untested = Enum.any?(status.triangle, &(&1.gap == :code_untested and &1.code in ids))

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
  def text(%{incomplete: incomplete} = report) do
    items =
      if incomplete == [],
        do: [],
        else: ["\nIncomplete:\n" | Enum.map(incomplete, &["  ", item_text(&1), "\n"])]

    IO.iodata_to_binary([summary(report), items])
  end

  @doc """
  The score lines of `text/1` alone: overall, then one line per kind. What a gate step
  prints, where the incomplete items would bury its other output.
  """
  @spec summary(t) :: String.t()
  def summary(%{scores: s}) do
    lines = for {kind, label} <- @kinds, do: "  #{label}: #{percent(s[kind])}\n"
    IO.iodata_to_binary(["completeness: #{percent(s.overall)}\n", lines])
  end

  defp percent(%{complete: c, total: t, percent: p}), do: "#{p}% (#{c}/#{t})"

  defp item_text(i), do: "#{i.kind} #{i.id}#{at(i.location)}: #{missing_text(i.missing)}"

  # What an item misses, as read: `deviates` names its references.
  defp missing_text(missing), do: Enum.map_join(missing, ", ", &lack/1)

  defp lack({:deviates, refs}), do: "deviates (#{Enum.join(refs, ", ")})"
  defp lack({:contained, units}), do: "contained (#{Enum.join(units, ", ")})"
  defp lack(atom), do: Atom.to_string(atom)

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
          "missing" => Enum.map(i.missing, &lack/1),
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
          %{"Item" => {:code, "#{i.kind} #{i.id}"}, "Missing" => missing_text(i.missing)}
        end
    }
  end

  @doc "Whether the report's overall score is below `min` (none when `min` is `nil`)."
  @spec below?(t, number | nil) :: boolean
  def below?(_report, nil), do: false
  def below?(report, min), do: report.scores.overall.percent < min
end
