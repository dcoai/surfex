defmodule Surfex.Status.Report do
  @moduledoc """
  A `Surfex.Status` as something to read: text for people, JSON for tools and agents.

  The JSON is the work list: for each relation that needs attention, what it is, which
  ends changed, what hash was recorded and what it is now, and where each end is. Nobody
  has to scan anything again to act on it.
  """

  alias Surfex.Status

  @doc "The status as text: the summary per relation type, then everything needing attention."
  @spec text(Status.t()) :: String.t()
  def text(status) do
    summary =
      for {type, counts} <- Enum.sort(Status.summary(status)) do
        parts = for {state, n} <- Enum.sort(counts), do: "#{state} #{n}"
        "  #{type}: #{Enum.join(parts, " · ")}"
      end

    unvalidated_relations = MapSet.new(status.unvalidated, & &1.relation)

    lists = [
      section(
        "Dangling (an end changed since it was confirmed)",
        status,
        &(&1.state == :dangling)
      ),
      section("Orphaned (an end is no longer scanned)", status, &(&1.state == :orphaned)),
      section(
        "Conflicted (recorded on two branches without seeing each other)",
        status,
        &(&1.state == :conflicted)
      ),
      section(
        "Proposed (a claim nothing has validated yet)",
        status,
        &(&1.state == :proposed)
      ),
      section("Impacted (an end depends on something not current)", status, & &1.impacted),
      section("Planned (an end doesn't exist yet)", status, &(&1.state == :planned)),
      items(
        "Unimplemented (every implements relation is planned)",
        status.unimplemented,
        &unit_text/1
      ),
      items("New (in no relation)", status.new, &unit_text/1),
      items("Unmet (required relation missing)", status.unmet, fn %{
                                                                    scan: scan,
                                                                    requires: requires
                                                                  } ->
        "#{scan.kind} #{scan.id} needs one of: #{Enum.join(requires, ", ")}#{at(scan)}"
      end),
      items(
        "Triangle (a spec unit, its tests and its code don't meet)",
        status.triangle,
        &gap_text/1
      ),
      items(
        "Broken citations (the spec names what the code doesn't have)",
        status.citations,
        fn c ->
          "#{c.file}:#{c.line} (#{c.section}): `#{c.span}` #{citation_text(c)}"
        end
      ),
      items(
        "Unproven (a confirmation by evidence this run doesn't bear out)",
        status.unproven,
        &claim_line/1
      ),
      # Information, not a failure: another job runs these (§17).
      items(
        "Not checked here (its test was excluded or skipped in this run)",
        status.unchecked,
        &claim_line/1
      ),
      # Listed only where they fail: a project moving over has many (§13.3).
      section(
        "Unvalidated (current, but nothing has validated it)",
        status,
        &(status.policy.validated and &1.relation in unvalidated_relations)
      ),
      items("Marked (the spec needs an update)", status.marks, &mark_text/1),
      items("Undeclared (a test no longer declares what it verifies)", status.undeclared, fn u ->
        "verifies  test #{u.test} → spec #{u.spec}"
      end),
      items("Stale (an excuse its class no longer covers)", status.stale, fn s ->
        "class #{s.class} ↔ code #{s.code}: #{stale_text(s.reason)}"
      end),
      items("Broken (a test declares what no spec unit is)", status.broken, fn b ->
        "#{b.scan.kind} #{b.scan.id} #{b.type} #{inspect(b.ref)}: #{reason(b.reason)}#{at(b.scan)}"
      end)
    ]

    verdict = if Status.failing?(status), do: "FAILING", else: "ok"
    counts = if summary == [], do: ["  (no relations)"], else: summary

    u = Status.units(status)

    units =
      "  spec units: sections #{u.section} · blocks #{u.block} · test hints #{u.test_hint}\n"

    unvalidated =
      case length(status.unvalidated) do
        0 -> []
        n -> "  unvalidated: #{n}\n"
      end

    # How much rests on trust rather than evidence or review (§18.1).
    baseline =
      case Status.baseline_count(status) do
        0 -> []
        n -> "  baseline: #{n} relations (adoption: #{inspect(status.adoption)})\n"
      end

    IO.iodata_to_binary([
      "relation status: #{verdict}\n",
      Enum.map(counts, &[&1, "\n"]),
      unvalidated,
      baseline,
      units,
      lists
    ])
  end

  @doc "The status as JSON: the summary, every relation, the new and the unmet."
  @spec json(Status.t()) :: String.t()
  def json(status) do
    %{
      "failing" => Status.failing?(status),
      "summary" =>
        Map.new(Status.summary(status), fn {type, counts} ->
          {Atom.to_string(type), Map.new(counts, fn {state, n} -> {Atom.to_string(state), n} end)}
        end),
      "relations" => Enum.map(status.relations, &relation_json(&1, status)),
      "units" =>
        status |> Status.units() |> Map.new(fn {role, n} -> {Atom.to_string(role), n} end),
      "new" => Enum.map(status.new, &scan_json/1),
      "unimplemented" => Enum.map(status.unimplemented, &scan_json/1),
      "unmet" =>
        Enum.map(status.unmet, fn %{scan: scan, requires: requires} ->
          Map.put(scan_json(scan), "requires", Enum.map(requires, &Atom.to_string/1))
        end),
      "triangle" =>
        Enum.map(status.triangle, fn g ->
          %{"spec" => g.spec, "gap" => Atom.to_string(g.gap), "test" => g.test, "code" => g.code}
        end),
      "citations" =>
        Enum.map(status.citations, fn c ->
          %{
            "span" => c.span,
            "file" => c.file,
            "line" => c.line,
            "section" => c.section,
            "status" => Atom.to_string(c.status),
            "items" => c.items
          }
        end),
      "unproven" => Enum.map(status.unproven, &claim_json/1),
      "unchecked" => Enum.map(status.unchecked, &claim_json/1),
      "undeclared" => Enum.map(status.undeclared, &%{"test" => &1.test, "spec" => &1.spec}),
      "baseline" => %{
        "relations" => Status.baseline_count(status),
        "adoption" => inspect(status.adoption)
      },
      "marks" =>
        Enum.map(status.marks, fn m ->
          %{
            "id" => m.id,
            "type" => Atom.to_string(m.type),
            "unit" => m.unit,
            "state" => Atom.to_string(m.state),
            "note" => m.note,
            "by" => m.by,
            "at" => m.at,
            "location" => m.location && location_json(m.location)
          }
        end),
      "unvalidated" =>
        Enum.map(status.unvalidated, fn %{relation: {type, {ak, a}, {bk, b}}} ->
          %{
            "type" => Atom.to_string(type),
            "ends" => [
              %{"kind" => Atom.to_string(ak), "id" => a},
              %{"kind" => Atom.to_string(bk), "id" => b}
            ]
          }
        end),
      "stale" =>
        Enum.map(status.stale, fn s ->
          %{"class" => s.class, "code" => s.code, "reason" => stale_text(s.reason)}
        end),
      "broken" =>
        Enum.map(status.broken, fn b ->
          Map.merge(scan_json(b.scan), %{
            "type" => Atom.to_string(b.type),
            "ref" => b.ref,
            "reason" => reason(b.reason)
          })
        end)
    }
    |> :json.encode(&encode/2)
    |> IO.iodata_to_binary()
  end

  @doc """
  The status as a `Surfex.Golden` spec, to commit and gate. It has a table per relation
  type (from, to, state, the ends that changed), then the new and the unmet ids. It holds
  no hashes and no times: it changes when a relation's state changes, not every time one
  is confirmed, and it stays a pure function of the scans and the log, so a merge
  conflict in it is resolved by regenerating.
  """
  @spec golden(Status.t(), String.t()) :: Surfex.Golden.spec()
  def golden(status, output \\ "RELATIONS.md") do
    counts = Enum.frequencies_by(status.relations, & &1.state)

    relation_groups =
      status.relations
      |> Enum.group_by(& &1.type)
      |> Enum.sort()
      |> Enum.map(fn {type, rs} ->
        %{heading: Atom.to_string(type), rows: Enum.map(rs, &golden_row/1)}
      end)

    id_group = fn heading, columns, list, fun ->
      if list == [],
        do: [],
        else: [%{heading: heading, columns: columns, rows: Enum.map(list, fun)}]
    end

    %{
      name: Path.basename(output),
      purpose: "Every spec↔code relation in the log, and whether it still holds.",
      task: "surfex.goldens",
      gate: "relation-status-drift",
      hardness: :hard,
      prose:
        "A row per relation. **dangling**: an end changed since it was confirmed (`mix surfex.confirm`). " <>
          "**orphaned**: an end is gone. **planned**: an end doesn't exist yet. **conflicted**: recorded on two branches (`mix surfex.resolve`). " <>
          "For `depends_on`, `refines` and `tests` the first end depends on, refines or tests the " <>
          "other; the other types' ends are in sorted order. `mix surfex.status` is the check; " <>
          "this is the record.",
      stats: [
        Surfex.Golden.stat("#{length(status.relations)} relations", [
          {"current", Map.get(counts, :current, 0)},
          {"dangling", Map.get(counts, :dangling, 0)},
          {"orphaned", Map.get(counts, :orphaned, 0)},
          {"conflicted", Map.get(counts, :conflicted, 0)},
          {"retired", Map.get(counts, :retired, 0)},
          {"planned", Map.get(counts, :planned, 0)},
          {"unimplemented", length(status.unimplemented)},
          {"new", length(status.new)},
          {"unmet", length(status.unmet)},
          {"broken", length(status.broken)},
          {"stale", length(status.stale)},
          {"undeclared", length(status.undeclared)},
          {"marks", length(status.marks)},
          {"baseline", Status.baseline_count(status)},
          {"broken citations", length(status.citations)},
          {"triangle gaps", length(status.triangle)}
        ]),
        units_stat(Status.units(status))
      ],
      columns: ["End", "Other end", "State", "Changed"],
      groups:
        relation_groups ++
          id_group.(
            "unimplemented",
            ["Item"],
            status.unimplemented,
            &%{"Item" => {:code, "#{&1.kind} #{&1.id}"}}
          ) ++
          id_group.(
            "new",
            ["Item"],
            status.new,
            &%{"Item" => {:code, "#{&1.kind} #{&1.id}"}}
          ) ++
          id_group.("triangle", ["Item", "Gap"], status.triangle, fn g ->
            %{"Item" => {:code, "spec #{g.spec}"}, "Gap" => {:raw, gap_text(g, false)}}
          end) ++
          id_group.("broken citations", ["Item", "Cited at"], status.citations, fn c ->
            %{
              "Item" => {:code, c.span},
              "Cited at" => {:raw, "`#{c.file}` · #{c.section}: #{citation_text(c)}"}
            }
          end) ++
          id_group.("marks", ["Item", "State", "Note"], status.marks, fn m ->
            %{
              "Item" => {:code, "spec #{m.unit}"},
              "State" => Atom.to_string(m.state),
              "Note" => {:raw, m.note || ""}
            }
          end) ++
          id_group.("undeclared", ["Item", "Verified"], status.undeclared, fn u ->
            %{"Item" => {:code, "test #{u.test}"}, "Verified" => {:code, "spec #{u.spec}"}}
          end) ++
          id_group.("stale", ["Item", "Excused as"], status.stale, fn s ->
            %{
              "Item" => {:code, "code #{s.code}"},
              "Excused as" => {:raw, "`#{s.class}`: #{stale_text(s.reason)}"}
            }
          end) ++
          id_group.("broken", ["Item", "Declares"], status.broken, fn b ->
            %{
              "Item" => {:code, "#{b.scan.kind} #{b.scan.id}"},
              "Declares" => {:raw, "`#{b.type} #{b.ref}`: #{reason(b.reason)}"}
            }
          end) ++
          id_group.("unmet", ["Item", "Needs"], status.unmet, fn %{scan: s, requires: r} ->
            %{
              "Item" => {:code, "#{s.kind} #{s.id}"},
              "Needs" => {:raw, Enum.map_join(r, ", ", &"`#{&1}`")}
            }
          end)
    }
  end

  defp golden_row(%{relation: {_type, {ak, aid}, {bk, bid}}} = r) do
    state = if r.impacted, do: {:raw, "`#{inspect(r.state)}` · impacted"}, else: {:atom, r.state}

    %{
      "End" => {:code, "#{ak} #{aid}"},
      "Other end" => {:code, "#{bk} #{bid}"},
      "State" => state,
      "Changed" =>
        if(r.changed == [],
          do: :absent,
          else: {:raw, Enum.map_join(r.changed, ", ", fn {k, id} -> "`#{k} #{id}`" end)}
        )
    }
  end

  # ── Text ────────────────────────────────────────────────────────────────

  defp section(title, status, pick) do
    rows =
      for r <- status.relations, pick.(r) do
        {type, a, b} = r.relation

        label = if r.state == :planned, do: "planned", else: "changed"

        changed =
          if r.changed == [],
            do: "",
            else: " (#{label}: #{Enum.map_join(r.changed, ", ", &describe(&1, status))})"

        tips =
          if r.state == :conflicted,
            do: " (tips: #{Enum.map_join(r.tips, ", ", &String.slice(&1.id, 0, 12))})",
            else: ""

        "#{type}  #{end_text(a)} ↔ #{end_text(b)}#{changed}#{tips}"
      end

    items(title, rows, & &1)
  end

  defp items(_title, [], _fun), do: []
  defp items(title, list, fun), do: ["\n", title, ":\n", Enum.map(list, &["  ", fun.(&1), "\n"])]

  defp end_text({kind, id}), do: "#{kind} #{id}"

  defp describe({_kind, id} = key, status) do
    case Map.get(status.scans, key) do
      nil -> id
      scan -> "#{id}#{at(scan)}"
    end
  end

  defp gap_text(g, with_spec? \\ true) do
    what =
      case g.gap do
        :no_test -> "no test verifies it"
        :test_misses_code -> "`#{g.test}` verifies it but calls none of its code"
        :code_untested -> "`#{g.code}` implements it but no verifying test calls it"
      end

    if with_spec?, do: "spec #{g.spec}: #{String.replace(what, "`", "")}", else: what
  end

  defp citation_text(%{status: :unresolved}), do: "names nothing the code has"

  defp citation_text(%{status: :ambiguous, items: items}),
    do: "names more than one item: #{Enum.join(items, ", ")}"

  # A claim by evidence and why this run doesn't bear it out, or didn't check it.
  defp claim_line(u) do
    {type, {ak, a}, {bk, b}} = u.relation
    test = if u.test, do: "#{u.test} ", else: ""
    "#{type}  #{ak} #{a} ↔ #{bk} #{b}: #{test}#{unproven_text(u.reason)}"
  end

  defp claim_json(u) do
    {type, {ak, a}, {bk, b}} = u.relation

    %{
      "type" => Atom.to_string(type),
      "ends" => [
        %{"kind" => Atom.to_string(ak), "id" => a},
        %{"kind" => Atom.to_string(bk), "id" => b}
      ],
      "test" => u.test,
      "reason" => unproven_text(u.reason)
    }
  end

  defp unproven_text(:not_run), do: "didn't run"
  defp unproven_text(:no_job), do: "no job's evidence ran it"
  defp unproven_text(:excluded), do: "excluded in this run"
  defp unproven_text(:skipped), do: "skipped in this run"
  defp unproven_text(:failed), do: "failed"
  defp unproven_text(:other_code), do: "ran against another version of the code"
  defp unproven_text(:no_verifying_test), do: "no current verifying test exercises the code"

  defp stale_text(:implemented), do: "something implements it now"
  defp stale_text(:unmatched), do: "no rule of its class matches it"
  defp stale_text({:other_class, class}), do: "class #{class}'s rule matches it first"

  defp reason(:unknown), do: "no spec unit has that id"
  defp reason({:ambiguous, ids}), do: "more than one does: #{Enum.join(ids, ", ")}"

  defp units_stat(u),
    do:
      Surfex.Golden.stat("#{u.section + u.block + u.test_hint} spec units", [
        {"sections", u.section},
        {"blocks", u.block},
        {"test hints", u.test_hint}
      ])

  # A block or hint says what it sits in, so a list of them reads under their sections.
  defp unit_text(%{kind: kind, id: id, role: role, within: within} = scan) when within != nil,
    do:
      "#{kind} #{id} (#{String.replace(Atom.to_string(role), "_", " ")} in #{within})#{at(scan)}"

  defp unit_text(scan), do: "#{scan.kind} #{scan.id}#{at(scan)}"

  # An open mark: the unit, where it is, what's wrong and who said so when.
  defp mark_text(%{state: :orphaned} = m),
    do: "spec #{m.unit} (no longer scanned): #{m.note} (#{m.by}, #{m.at})"

  defp mark_text(m), do: "spec #{m.unit}#{at(m)}: #{m.note} (#{m.by}, #{m.at})"

  defp at(%{location: %{file: file, lines: {first, last}}}), do: " (#{file}:#{first}-#{last})"
  defp at(%{location: %{file: file}}), do: " (#{file})"

  # ── JSON ────────────────────────────────────────────────────────────────

  # OTP's encoder writes only the atom `:null` as null, and any other atom, `nil` too, as a
  # string. Absent values (a gone end's hash and location, a conflicted relation's recorded
  # hashes) must reach tools as null, not as a hash named "nil".
  defp encode(nil, _encoder), do: "null"
  defp encode(value, encoder), do: :json.encode_value(value, encoder)

  defp relation_json(r, status) do
    {type, a, b} = r.relation
    recorded = recorded_hashes(r)

    %{
      "type" => Atom.to_string(type),
      "state" => Atom.to_string(r.state),
      "impacted" => r.impacted,
      "ends" =>
        Enum.map([a, b], fn {kind, id} = key ->
          scan = Map.get(status.scans, key)

          %{
            "kind" => Atom.to_string(kind),
            "id" => id,
            "recorded" => Map.get(recorded, key),
            "now" => scan && scan.hash,
            # A planned relation's `changed` names the ends still waiting to exist.
            "changed" => r.state != :planned and key in r.changed,
            "planned" => r.state == :planned and key in r.changed,
            "location" => scan && location_json(scan.location)
          }
        end),
      "tips" => Enum.map(r.tips, & &1.id)
    }
  end

  # The hashes the tip recorded for each end (none when conflicted: there is no one tip).
  defp recorded_hashes(%{tips: [tip]}), do: Map.new(tip.ends, &{{&1.kind, &1.id}, &1.hash})
  defp recorded_hashes(_), do: %{}

  defp scan_json(scan) do
    %{
      "kind" => Atom.to_string(scan.kind),
      "id" => scan.id,
      "hash" => scan.hash,
      "role" => scan.role && Atom.to_string(scan.role),
      "within" => scan.within,
      "declares" =>
        Enum.map(scan.declares, fn {type, ref} ->
          %{"type" => Atom.to_string(type), "ref" => ref}
        end),
      "location" => location_json(scan.location)
    }
  end

  defp location_json(%{file: file, lines: {first, last}}),
    do: %{"file" => file, "lines" => [first, last]}

  defp location_json(%{file: file}), do: %{"file" => file, "lines" => nil}
end
