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
      section("Impacted (an end depends on something not current)", status, & &1.impacted),
      items("New (in no relation)", status.new, fn scan ->
        "#{scan.kind} #{scan.id}#{at(scan)}"
      end),
      items("Unmet (required relation missing)", status.unmet, fn %{
                                                                    scan: scan,
                                                                    requires: requires
                                                                  } ->
        "#{scan.kind} #{scan.id} needs one of: #{Enum.join(requires, ", ")}#{at(scan)}"
      end)
    ]

    verdict = if Status.failing?(status), do: "FAILING", else: "ok"
    counts = if summary == [], do: ["  (no relations)"], else: summary

    IO.iodata_to_binary([
      "relation status: #{verdict}\n",
      Enum.map(counts, &[&1, "\n"]),
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
      "new" => Enum.map(status.new, &scan_json/1),
      "unmet" =>
        Enum.map(status.unmet, fn %{scan: scan, requires: requires} ->
          Map.put(scan_json(scan), "requires", Enum.map(requires, &Atom.to_string/1))
        end)
    }
    |> :json.encode()
    |> IO.iodata_to_binary()
  end

  # ── Text ────────────────────────────────────────────────────────────────

  defp section(title, status, pick) do
    rows =
      for r <- status.relations, pick.(r) do
        {type, a, b} = r.relation

        changed =
          if r.changed == [],
            do: "",
            else: " (changed: #{Enum.map_join(r.changed, ", ", &describe(&1, status))})"

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

  defp at(%{location: %{file: file, lines: {first, last}}}), do: " (#{file}:#{first}-#{last})"
  defp at(%{location: %{file: file}}), do: " (#{file})"

  # ── JSON ────────────────────────────────────────────────────────────────

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
            "changed" => key in r.changed,
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
      "location" => location_json(scan.location)
    }
  end

  defp location_json(%{file: file, lines: {first, last}}),
    do: %{"file" => file, "lines" => [first, last]}

  defp location_json(%{file: file}), do: %{"file" => file, "lines" => nil}
end
