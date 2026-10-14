defmodule Surfex.Status.Report do
  @moduledoc """
  A `Surfex.Status` as something to read: text for people, JSON for tools and agents.

  The JSON is the work list: for each relation that needs attention, what it is, which
  ends changed, what hash was recorded and what it is now, and where each end is. Nobody
  has to scan anything again to act on it.
  """

  alias Surfex.Golden.Span
  alias Surfex.Log.Entry
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
      # Listed, not failing (§14.1): a section moving to its claims, one commit or several.
      items(
        "Migrating (a section's implements moving to its claims)",
        status.migrating,
        &migrating_line/1
      ),
      # Listed, not failing (§13.1): the declared state of a project fixing its code.
      items(
        "Deviating (a test declares the code doesn't meet the unit yet)",
        Enum.reject(status.deviating, &(&1.run == :passed)),
        &deviating_line(&1, status)
      ),
      items(
        "Stale deviations (a deviation test passed: drop the tag and validate)",
        Enum.filter(status.deviating, &(&1.run == :passed)),
        &deviating_line(&1, status)
      ),
      items(
        "Unimplemented (every implements relation is planned)",
        status.unimplemented,
        &unit_text/1
      ),
      items("New (in no relation)", status.new, &unit_text/1),
      # Listed where a project declares any, so other reports read as before (§11.4).
      items("Checks (gates that verify claims)", checks(status), &check_line/1),
      items("Unmet (required relation missing)", status.unmet, &unmet_line/1),
      # Under claim_grain: true (§13.9): failing where `require: code:` asks for an
      # implements, listed otherwise.
      items(
        "Unearned (an implements no verified claim's test or check exercises: it meets no require: code: rule)",
        status.unearned,
        &"implements  code #{&1.code} → spec #{&1.unit}: #{unearned_text(&1.why)}"
      ),
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
        "Failed (its test failed in this run, whatever validated the relation)",
        status.failed,
        &failed_line/1
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
      # Information, not a failure (§17): what made the test pass is outside its reach.
      items(
        "Uncredited (red then green against the same code: what changed is outside its reach)",
        status.uncredited,
        &uncredited_line(&1, status)
      ),
      # Listed only where they fail: a project moving over has many (§13.3).
      section(
        "Unvalidated (current, but nothing has validated it)",
        status,
        &(status.policy.validated and &1.relation in unvalidated_relations)
      ),
      items("Marked (the spec needs an update)", status.marks, &mark_text/1),
      items("Undeclared (a test no longer declares what it verifies)", status.undeclared, fn u ->
        "verifies  #{verifier(u.test)} → spec #{u.spec}"
      end),
      items(
        "Unrecorded (a test declares what the log doesn't record)",
        status.unrecorded,
        &"verifies  #{verifier(&1.test, status)} → spec #{&1.spec}: #{unrecorded_text(&1)}"
      ),
      items(
        "Moved (a unit no longer sits in what it refines)",
        status.moved,
        &"refines  spec #{describe({:spec, &1.from}, status)} → spec #{&1.to}: #{moved_text(&1)}"
      ),
      # Failing under claim_grain: true (§13.6): one of the class and the relation is wrong.
      items(
        "Contradicted (a relation to a unit its class says asserts nothing: retire the relation, or remove the class)",
        status.contradicted,
        &contradicted_line/1
      ),
      # Failing under claim_grain: true (§13.7): the deferral no longer holds.
      items(
        "Stale deferrals (built, its issue closed, or the tracker couldn't say: remove or re-defer)",
        status.stale_deferrals,
        &"spec #{&1.unit} deferred by #{&1.ref}: #{stale_deferral_text(&1.reason)}"
      ),
      items("Stale (an excuse its class no longer covers)", status.stale, fn s ->
        "class #{s.class} ↔ code #{s.code}: #{stale_text(s.reason)}"
      end),
      items("Broken (a test declares what no spec unit is)", status.broken, fn b ->
        "#{b.scan.kind} #{b.scan.id} #{b.type} #{inspect(b.ref)}: #{reason(b.reason)}#{at(b.scan)}"
      end),
      # Information, not a failure (§13.4): green only through a claim inside it.
      items(
        "Contained (a claim verified only through a claim inside it: its own text isn't)",
        status.contained,
        &contained_line(&1, status)
      ),
      items(
        "On a container (a verifies aimed at a unit with no text of its own verifies nothing)",
        status.on_container,
        &on_container_line/1
      ),
      # Information, not a failure (§11.5): a tag that verifies nothing.
      items(
        "Inert (a verifies tag outside any test: it verifies nothing)",
        status.inert,
        &"#{&1.file}:#{&1.line} verifies #{Enum.join(&1.ids, ", ")}: #{inert_text(&1.reason)}"
      ),
      # A warning, not a failure (§11.2).
      items(
        "List-shaped keys (a table row's key that may name two things)",
        Status.list_keys(status),
        &"row #{&1.row.id} in table #{&1.table}: its key holds #{inspect(&1.separator)}#{at(&1.row)}"
      )
    ]

    verdict = if Status.failing?(status), do: "FAILING", else: "ok"
    counts = if summary == [], do: ["  (no relations)"], else: summary

    u = Status.units(status)

    # Tables and rows only where a spec marks tables (§11), so other reports read as before.
    tables = if u.table > 0, do: " · tables #{u.table} · rows #{u.row}", else: ""
    # Rules only where a spec names claims (§11.1).
    tables = if u.rule > 0, do: tables <> " · rules #{u.rule}", else: tables
    tables = if u.contract > 0, do: tables <> " · contracts #{u.contract}", else: tables

    units =
      "  spec units: sections #{u.section} · blocks #{u.block} · test hints #{u.test_hint}#{tables}\n"

    unvalidated =
      case length(status.unvalidated) do
        0 -> []
        n -> "  unvalidated: #{n}\n"
      end

    # Counted, not listed: a project that tags with lists has many (§13.3). The JSON lists them.
    unselectable =
      case length(status.unselectable) do
        0 -> []
        1 -> "  unselectable by --only: 1 test\n"
        n -> "  unselectable by --only: #{n} tests\n"
      end

    # How much rests on trust rather than evidence or review (§18.1).
    baseline =
      case Status.baseline_count(status) do
        0 -> []
        n -> "  baseline: #{n} relations (adoption: #{inspect(status.adoption)})\n"
      end

    # Reviews that named how their test exercises code no call reaches (§18).
    through =
      case Status.through_count(status) do
        0 -> []
        1 -> "  reviewed through a named path: 1 relation\n"
        n -> "  reviewed through a named path: #{n} relations\n"
      end

    IO.iodata_to_binary([
      "relation status: #{verdict}\n",
      Enum.map(counts, &[&1, "\n"]),
      unvalidated,
      unselectable,
      baseline,
      through,
      units,
      claims_text(status),
      unearned_count(status),
      classed_text(status),
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
      "checks" =>
        Enum.map(checks(status), fn s ->
          Map.merge(scan_json(s), %{
            "run" => s.check.run,
            "declaration" => s.check.declaration,
            "inputs" => s.check.inputs
          })
        end),
      "list_keys" =>
        Enum.map(Status.list_keys(status), fn k ->
          Map.merge(scan_json(k.row), %{"table" => k.table, "separator" => k.separator})
        end),
      "unimplemented" => Enum.map(status.unimplemented, &scan_json/1),
      "verdicts" => Map.new(status.verdicts, fn {unit, v} -> {unit, Atom.to_string(v)} end),
      "contained" =>
        Enum.map(status.contained, fn c ->
          %{"unit" => c.unit, "inside" => c.inside, "location" => location_json(c.location)}
        end),
      "on_container" =>
        Enum.map(
          status.on_container,
          &%{"test" => &1.test, "unit" => &1.unit, "inside" => &1.inside}
        ),
      "excused" =>
        Enum.map(status.excused, fn e ->
          %{
            "unit" => e.unit,
            "class" => e.name,
            "reason" => e.reason,
            "note" => e.note,
            "by" => Atom.to_string(e.by),
            "claims" => e.claims,
            "location" => location_json(e.location)
          }
        end),
      "deferred" =>
        Enum.map(status.deferred, fn d ->
          %{
            "unit" => d.unit,
            "ref" => d.ref,
            "reason" => d.reason,
            "issue" => d.issue && Atom.to_string(d.issue),
            "location" => location_json(d.location)
          }
        end),
      "stale_deferrals" =>
        Enum.map(
          status.stale_deferrals,
          &%{"unit" => &1.unit, "ref" => &1.ref, "reason" => Atom.to_string(&1.reason)}
        ),
      "contradicted" =>
        Enum.map(
          status.contradicted,
          &%{"type" => Atom.to_string(&1.type), "from" => &1.from, "unit" => &1.unit}
        ),
      "containers" =>
        Enum.map(
          status.containers,
          &%{"unit" => &1.unit, "claims" => &1.claims, "verified" => &1.verified}
        ),
      "unearned" =>
        Enum.map(
          status.unearned,
          &%{"code" => &1.code, "unit" => &1.unit, "why" => Atom.to_string(&1.why)}
        ),
      "unmet" =>
        Enum.map(status.unmet, fn %{scan: scan, requires: requires} = u ->
          scan_json(scan)
          |> Map.put("requires", Enum.map(requires, &Atom.to_string/1))
          |> Map.put("why", u.why && Atom.to_string(u.why))
        end),
      "triangle" =>
        Enum.map(status.triangle, fn g ->
          %{"spec" => g.spec, "gap" => Atom.to_string(g.gap), "test" => g.test, "code" => g.code}
        end),
      "inert" =>
        Enum.map(status.inert, fn i ->
          %{
            "file" => i.file,
            "line" => i.line,
            "ids" => i.ids,
            "reason" => Atom.to_string(i.reason)
          }
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
      "failed" => Enum.map(status.failed, &failed_json/1),
      "unproven" => Enum.map(status.unproven, &claim_json/1),
      "unchecked" => Enum.map(status.unchecked, &claim_json/1),
      "uncredited" => Enum.map(status.uncredited, &%{"test" => &1.test, "code" => &1.code}),
      "undeclared" => Enum.map(status.undeclared, &%{"test" => &1.test, "spec" => &1.spec}),
      "unrecorded" =>
        Enum.map(status.unrecorded, fn u ->
          %{
            "test" => u.test,
            "spec" => u.spec,
            "retired" => u.retired != nil,
            "note" => u.retired && u.retired.note
          }
        end),
      "moved" => Enum.map(status.moved, &%{"from" => &1.from, "to" => &1.to, "now" => &1.now}),
      "migrating" =>
        Enum.map(
          status.migrating,
          &%{
            "code" => &1.code,
            "section" => &1.section,
            "claims" => &1.claims,
            "settled" => &1.settled
          }
        ),
      "unselectable" => Enum.map(status.unselectable, &%{"test" => &1.test, "ids" => &1.ids}),
      "deviating" =>
        Enum.map(status.deviating, fn d ->
          %{
            "spec" => d.spec,
            "test" => d.test,
            "ref" => d.ref,
            "run" => d.run && Atom.to_string(d.run),
            "stale" => d.run == :passed
          }
        end),
      "baseline" => %{
        "relations" => Status.baseline_count(status),
        "adoption" => inspect(status.adoption)
      },
      "through" => Status.through_count(status),
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
          "**deviates**: proposed, to a unit a test declares the code doesn't meet yet (`@tag deviation:`), listed with its reference under `deviating`. " <>
          migrating_prose(status) <>
          "For `depends_on`, `refines` and `tests` the first end depends on, refines or tests the " <>
          "other; the other types' ends are in sorted order. `mix surfex.status` is the check; " <>
          "this is the record.",
      stats: [
        Surfex.Golden.stat(
          "#{length(status.relations)} relations",
          [
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
            {"unrecorded", length(status.unrecorded)},
            {"moved", length(status.moved)},
            {"deviating", length(status.deviating)},
            {"marks", length(status.marks)},
            {"baseline", Status.baseline_count(status)}
            | through_stat(status)
          ] ++
            check_stat(status) ++
            if(status.inert == [], do: [], else: [{"inert tags", length(status.inert)}]) ++
            classed_stat(status) ++
            unearned_stat(status) ++
            [
              {"broken citations", length(status.citations)},
              {"triangle gaps", length(status.triangle)}
            ]
        ),
        units_stat(Status.units(status)),
        claims_stat(status)
      ],
      columns: ["End", "Other end", "State", "Changed"],
      # By file, not line, so the golden doesn't drift when lines move.
      # Keyed by unit (§13.6): a new excusal is a row a reviewer sees in the diff.
      groups:
        relation_groups ++
          id_group.("migrating", ["Item", "Moving"], status.migrating, fn m ->
            %{
              "Item" => {:code, "code #{m.code}"},
              "Moving" =>
                {:raw,
                 [
                   Span.code(m.section),
                   " → ",
                   Enum.map_intersperse(m.claims, ", ", &Span.code/1),
                   if(m.settled, do: " (settled)", else: "")
                 ]}
            }
          end) ++
          id_group.("unearned", ["Item", "Implements"], status.unearned, fn u ->
            %{
              "Item" => {:code, "code #{u.code}"},
              "Implements" => {:raw, coded("spec #{u.unit}", Atom.to_string(u.why))}
            }
          end) ++
          id_group.("contained", ["Item", "Verified inside"], status.contained, fn c ->
            %{
              "Item" => {:code, "spec #{c.unit}"},
              "Verified inside" => {:raw, Enum.map_intersperse(c.inside, ", ", &Span.code/1)}
            }
          end) ++
          id_group.("on container", ["Item", "Container"], status.on_container, fn o ->
            %{"Item" => {:code, verifier(o.test)}, "Container" => {:code, "spec #{o.unit}"}}
          end) ++
          id_group.("excused", ["Item", "Class", "By"], status.excused, fn e ->
            %{
              "Item" => {:code, "spec #{e.unit}"},
              "Class" => {:code, e.name},
              "By" => Atom.to_string(e.by)
            }
          end) ++
          id_group.("deferred", ["Item", "Reference"], status.deferred, fn d ->
            %{"Item" => {:code, "spec #{d.unit}"}, "Reference" => {:raw, Span.text(d.ref)}}
          end) ++
          id_group.("contradicted", ["Item", "Relation"], status.contradicted, fn c ->
            %{
              "Item" => {:code, "spec #{c.unit}"},
              "Relation" => {:raw, coded("#{c.type} #{c.from}", "its class excuses the unit")}
            }
          end) ++
          id_group.("stale deferrals", ["Item", "Deferral"], status.stale_deferrals, fn d ->
            %{
              "Item" => {:code, "spec #{d.unit}"},
              "Deferral" => {:raw, coded(d.ref, stale_deferral_text(d.reason))}
            }
          end) ++
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
          id_group.("checks", ["Item", "Verifies"], checks(status), fn s ->
            %{
              "Item" => {:code, "check #{s.id}"},
              "Verifies" =>
                {:raw, Enum.map_intersperse(s.declares, ", ", fn {_, ref} -> Span.code(ref) end)}
            }
          end) ++
          id_group.("triangle", ["Item", "Gap"], status.triangle, fn g ->
            %{"Item" => {:code, "spec #{g.spec}"}, "Gap" => {:raw, gap_what(g, &Span.code/1)}}
          end) ++
          id_group.("broken citations", ["Item", "Cited at"], status.citations, fn c ->
            %{
              "Item" => {:code, c.span},
              "Cited at" =>
                {:raw, [Span.code(c.file), " · ", Span.text([c.section, ": ", citation_text(c)])]}
            }
          end) ++
          id_group.("inert", ["Item", "Verifies"], status.inert, fn i ->
            %{
              "Item" => {:code, i.file},
              "Verifies" => {:raw, coded(Enum.join(i.ids, ", "), inert_text(i.reason))}
            }
          end) ++
          id_group.("marks", ["Item", "State", "Note"], status.marks, fn m ->
            %{
              "Item" => {:code, "spec #{m.unit}"},
              "State" => Atom.to_string(m.state),
              "Note" => {:raw, Span.text(m.note || "")}
            }
          end) ++
          id_group.("undeclared", ["Item", "Verified"], status.undeclared, fn u ->
            %{"Item" => {:code, verifier(u.test)}, "Verified" => {:code, "spec #{u.spec}"}}
          end) ++
          id_group.("unrecorded", ["Item", "Declares"], status.unrecorded, fn u ->
            %{
              "Item" => {:code, verifier(u.test)},
              "Declares" => {:raw, coded("spec #{u.spec}", unrecorded_text(u))}
            }
          end) ++
          id_group.("deviating", ["Item", "Deviation", "Test"], status.deviating, fn d ->
            %{
              "Item" => {:code, "spec #{d.spec}"},
              "Deviation" => {:raw, Span.text(d.ref)},
              "Test" => {:code, "test #{d.test}"}
            }
          end) ++
          id_group.("moved", ["Item", "Refines"], status.moved, fn m ->
            %{
              "Item" => {:code, "spec #{m.from}"},
              "Refines" => {:raw, coded("spec #{m.to}", moved_text(m))}
            }
          end) ++
          id_group.("stale", ["Item", "Excused as"], status.stale, fn s ->
            %{
              "Item" => {:code, "code #{s.code}"},
              "Excused as" => {:raw, coded(to_string(s.class), stale_text(s.reason))}
            }
          end) ++
          id_group.("broken", ["Item", "Declares"], status.broken, fn b ->
            %{
              "Item" => {:code, "#{b.scan.kind} #{b.scan.id}"},
              "Declares" => {:raw, coded("#{b.type} #{b.ref}", reason(b.reason))}
            }
          end) ++
          id_group.("unmet", ["Item", "Needs"], status.unmet, fn %{scan: s, requires: r} = u ->
            %{
              "Item" => {:code, "#{s.kind} #{s.id}"},
              "Needs" =>
                {:raw,
                 [
                   Enum.map_intersperse(r, ", ", &Span.code(to_string(&1))),
                   if(u.why, do: Span.text(" (#{u.why})"), else: [])
                 ]}
            }
          end)
    }
  end

  defp golden_row(%{relation: {_type, {ak, aid}, {bk, bid}}} = r) do
    flags =
      for {true, flag} <- [
            {r.impacted, "impacted"},
            {r.deviates != [], "deviates"},
            {r.migrates != nil, "migrating"}
          ],
          do: flag

    state =
      if flags == [],
        do: {:atom, r.state},
        else: {:raw, Enum.intersperse([Span.code(inspect(r.state)) | flags], " · ")}

    %{
      "End" => {:code, "#{ak} #{aid}"},
      "Other end" => {:code, "#{bk} #{bid}"},
      "State" => state,
      "Changed" =>
        if(r.changed == [],
          do: :absent,
          else:
            {:raw,
             Enum.map_intersperse(r.changed, ", ", fn {k, id} -> Span.code("#{k} #{id}") end)}
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

        deviates =
          if r.deviates == [], do: "", else: " (deviates: #{Enum.join(r.deviates, ", ")})"

        migrates = if r.migrates, do: " (migrating from #{r.migrates})", else: ""

        "#{type}  #{end_text(a)} ↔ #{end_text(b)}#{changed}#{tips}#{deviates}#{migrates}"
      end

    items(title, rows, & &1)
  end

  # A code item moving from a section to its claims (§14.1), and what settles it.
  defp migrating_line(%{settled: true} = m),
    do:
      "implements  code #{m.code}: #{m.section} → #{Enum.join(m.claims, ", ")}: settled, " <>
        "every claim holds it; mix surfex.suggest --accept retires the section's relation"

  defp migrating_line(m),
    do:
      "implements  code #{m.code}: #{m.section} → #{Enum.join(m.claims, ", ")}: " <>
        "the section keeps its relation until the claim's is validated"

  # What an unrecorded declaration is, and the two explicit acts that settle it (§13.1).
  defp unrecorded_text(%{retired: nil}),
    do: "no verifies relation is recorded: record it (mix surfex.suggest), or remove the tag"

  defp unrecorded_text(%{retired: %{note: note}}),
    do:
      "declared, but the relation was retired (#{note || "no note"}): remove the tag, or reinstate it"

  # A test whose red→green can't be credited, and the code it reached in both runs (§17).
  defp uncredited_line(%{test: test, code: code}, status) do
    reached = if code == [], do: "no scanned code", else: "only #{Enum.join(code, ", ")}"
    "test #{describe({:test, test}, status)}: reached #{reached}"
  end

  # A deviating unit, its reference and test, and what the run says of it (§13.1).
  defp deviating_line(d, status),
    do:
      "spec #{describe({:spec, d.spec}, status)}: #{d.ref}, declared by test #{d.test}" <>
        deviation_run(d.run)

  defp deviation_run(nil), do: ""
  defp deviation_run(:failed), do: " (failed in this run, as declared)"

  defp deviation_run(:passed),
    do: " (passed in this run: the code meets it now, so drop the tag and validate)"

  defp deviation_run(other), do: " (#{other} in this run)"

  # Where a moved unit sits now, and what settles it (§13.1).
  defp moved_text(%{now: now}),
    do: "it now sits in #{now}: retire it and relate the new one (mix surfex.suggest --accept)"

  defp items(_title, [], _fun), do: []
  defp items(title, list, fun), do: ["\n", title, ":\n", Enum.map(list, &["  ", fun.(&1), "\n"])]

  defp end_text({kind, id}), do: "#{kind} #{id}"

  # A verifier as a list names it: a check is listed as `check ID` (§11.4), a test by id.
  defp verifier("check " <> _ = check), do: check
  defp verifier(test), do: "test #{test}"

  defp verifier("check " <> _ = check, _status), do: check
  defp verifier(test, status), do: "test #{describe({:test, test}, status)}"

  # The declared checks (§11.4), by id: their record and what they declare.
  defp checks(status),
    do: for({{:check, _}, scan} <- Enum.sort(status.scans), do: scan)

  defp check_line(scan) do
    refs = Enum.map_join(scan.declares, ", ", fn {_type, ref} -> ref end)
    inputs = map_size(scan.check.inputs)

    "check #{scan.id}: verifies #{refs}; inspects #{inputs} #{if inputs == 1, do: "file", else: "files"}"
  end

  defp describe({_kind, id} = key, status) do
    case Map.get(status.scans, key) do
      nil -> id
      scan -> "#{id}#{at(scan)}"
    end
  end

  defp gap_text(g), do: IO.iodata_to_binary(["spec #{g.spec}: ", gap_what(g, & &1)])

  # What a triangle gap lacks, naming its test or code through `name` (plain in the text
  # report, a code span in the golden).
  defp gap_what(g, name) do
    case g.gap do
      :no_test -> "no test verifies it"
      :test_misses_code -> [name.(g.test), " verifies it but calls none of its code"]
      :code_untested -> [name.(g.code), " implements it but no verifying test calls it"]
    end
  end

  # A golden cell naming an item, then saying something about it: `` `item`: text ``.
  defp coded(item, text), do: [Span.code(item), ": ", Span.text(text)]

  defp citation_text(%{status: :unresolved}), do: "names nothing the code has"

  defp citation_text(%{status: :ambiguous, items: items}),
    do: "names more than one item: #{Enum.join(items, ", ")}"

  # A relation whose test failed in this run, whatever its basis.
  defp failed_line(%{relation: {type, {ak, a}, {bk, b}}, test: test}),
    do: "#{type}  #{ak} #{a} ↔ #{bk} #{b}: #{test} failed"

  defp failed_json(%{relation: {type, {ak, a}, {bk, b}}, test: test}) do
    %{
      "type" => Atom.to_string(type),
      "ends" => [
        %{"kind" => Atom.to_string(ak), "id" => a},
        %{"kind" => Atom.to_string(bk), "id" => b}
      ],
      "test" => test
    }
  end

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

  # Why a verifies tag verifies nothing (§11.5).
  defp inert_text(:no_test), do: "no test or property block takes it"
  defp inert_text(:support), do: "in test/support, which runs no test"

  defp stale_text(:implemented), do: "something implements it now"
  defp stale_text(:unmatched), do: "no rule of its class matches it"
  defp stale_text({:other_class, class}), do: "class #{class}'s rule matches it first"

  defp reason(:unknown), do: "no spec unit has that id"
  defp reason(:no_unit), do: "the test declares no spec unit to deviate from"
  defp reason({:ambiguous, ids}), do: "more than one does: #{Enum.join(ids, ", ")}"

  defp units_stat(u),
    do:
      Surfex.Golden.stat(
        "#{u.section + u.block + u.test_hint + u.table + u.row + u.rule + u.contract} spec units",
        [{"sections", u.section}, {"blocks", u.block}, {"test hints", u.test_hint}] ++
          if(u.table > 0, do: [{"tables", u.table}, {"rows", u.row}], else: []) ++
          if(u.rule > 0, do: [{"rules", u.rule}], else: []) ++
          if(u.contract > 0, do: [{"contracts", u.contract}], else: [])
      )

  # A contained claim's line says why its rule isn't met (§13.4), and code whose
  # implements earn nothing says so (§13.9).
  defp unmet_line(%{scan: scan, requires: requires, why: why}) do
    because =
      case why do
        :contained -> ": contained: a unit inside it is verified, its own text isn't"
        :unearned -> ": unearned: none of its implements earns (see Unearned)"
        nil -> ""
      end

    "#{scan.kind} #{scan.id} needs one of: #{Enum.join(requires, ", ")}#{at(scan)}#{because}"
  end

  # Why an implements earns nothing (§13.5).
  defp unearned_text(:unverified), do: "unverified: no evidence, on the unit or a claim inside it"

  defp unearned_text(:not_exercised),
    do:
      "not_exercised: a claim inside is verified, but none of its tests or checks exercises the code"

  defp unearned_text(:nothing_inside), do: "nothing_inside: a container with no claims"

  # Counted under claim_grain: true (§13.9), so other reports read as before.
  defp unearned_count(%{policy: %{claim_grain: true}} = status) do
    fails = if status.policy.unearned == :fail, do: " (failing: require: code:)", else: ""
    "  unearned: #{length(status.unearned)} implements#{fails}\n"
  end

  defp unearned_count(_status), do: []

  defp unearned_stat(%{policy: %{claim_grain: true}} = status),
    do: [{"unearned", length(status.unearned)}]

  defp unearned_stat(_status), do: []

  # The spec units by verdict (§13.4): the claims, and the containers apart.
  defp verdict_counts(status) do
    f = status.verdicts |> Map.values() |> Enum.frequencies()
    claims = Map.get(f, :verified, 0) + Map.get(f, :contained, 0) + Map.get(f, :unverified, 0)

    {claims,
     [
       {"verified", Map.get(f, :verified, 0)},
       {"contained", Map.get(f, :contained, 0)},
       {"unverified", Map.get(f, :unverified, 0)},
       {"containers", Map.get(f, :through_claims, 0)}
     ]}
  end

  defp claims_stat(status) do
    {claims, counts} = verdict_counts(status)
    Surfex.Golden.stat("#{claims} claims", counts)
  end

  defp claims_text(status) do
    {claims, counts} = verdict_counts(status)
    "  claims: #{claims} · " <> Enum.map_join(counts, " · ", fn {k, n} -> "#{k} #{n}" end) <> "\n"
  end

  # The golden's counts of classed units, where a spec has any (§13.6).
  defp classed_stat(%{excused: [], deferred: []}), do: []

  defp classed_stat(status),
    do: [
      {"excused", length(status.excused)},
      {"deferred", length(status.deferred)},
      {"contradicted", length(status.contradicted)},
      {"stale deferrals", length(status.stale_deferrals)}
    ]

  # Classed and deferred units, counted where a spec has any (§13.6).
  defp classed_text(%{excused: [], deferred: []}), do: []

  defp classed_text(status) do
    with_claims = Enum.count(status.excused, &(&1.claims != []))

    "  excused by class: #{length(status.excused)} (#{with_claims} with claims inside) · " <>
      "deferred: #{length(status.deferred)}\n"
  end

  defp stale_deferral_text(:built),
    do: "it has its own evidence now: remove the marker"

  defp stale_deferral_text(:closed),
    do: "its issue is closed: remove the marker, or re-defer with the issue that holds the work"

  defp stale_deferral_text(:unresolved),
    do: "the tracker couldn't say whether its issue is open"

  defp contradicted_line(%{type: :declares} = c),
    do: "verifies  #{verifier(c.from)} declares spec #{c.unit}, which its class excuses"

  defp contradicted_line(%{type: :verifies} = c),
    do: "verifies  #{verifier(c.from)} → spec #{c.unit}, which its class excuses"

  defp contradicted_line(%{type: :implements} = c),
    do: "implements  code #{c.from} → spec #{c.unit}, which its class excuses"

  defp contained_line(c, status),
    do:
      "spec #{c.unit}#{at(Map.fetch!(status.scans, {:spec, c.unit}))}: verified inside: " <>
        Enum.join(c.inside, ", ")

  defp on_container_line(o),
    do: "#{verifier(o.test)} → spec #{o.unit}: its claims are #{claims_list(o.inside)}"

  defp claims_list([]), do: "none"
  defp claims_list(inside), do: Enum.join(inside, ", ")

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
      "deviates" => r.deviates,
      "migrates" => r.migrates,
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
      "tips" => Enum.map(r.tips, & &1.id),
      "through" => r.tip && r.tip.through
    }
  end

  # Said only where a section is migrating (§14.1), so other goldens read as before.
  defp migrating_prose(%{migrating: []}), do: ""

  defp migrating_prose(_status),
    do:
      "**migrating**: proposed, a claim's relation moving from the section listed under `migrating`, which keeps its own until this one is validated. "

  # A row only where a project declares checks (§11.4), so others keep their golden.
  defp check_stat(status) do
    case length(checks(status)) do
      0 -> []
      n -> [{"checks", n}]
    end
  end

  # A row only when some review named a path (§18), so a project with none keeps its
  # golden as it was.
  defp through_stat(status) do
    case Status.through_count(status) do
      0 -> []
      n -> [{"reviewed through a named path", n}]
    end
  end

  # The hashes the tip recorded for each end (none when conflicted: there is no one tip).
  defp recorded_hashes(%{tip: %Entry{} = tip}),
    do: Map.new(tip.ends, &{{&1.kind, &1.id}, &1.hash})

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
