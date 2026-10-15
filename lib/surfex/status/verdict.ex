defmodule Surfex.Status.Verdict do
  @moduledoc false
  # What "verified" means for a spec unit (spec §13.4), computed once per derive.
  #
  # A unit's **own text** is what its version covers: its body without the finer units
  # inside it, without markers and without the lines a `not_claims:` pattern matches
  # (`Surfex.Scan.Markdown.claimless?/1`, §13.12). A **claim** has own
  # text: a section or block whose own text isn't empty, and every hint, rule, row and
  # contract. A **container** has none: a heading over subsections, a section whose whole
  # body is named claims, a marked table (its version is its header, which is structure).
  #
  # Each unit gets one verdict, from the current `verifies` of tests and checks:
  #
  #   * `:verified` — a claim with a current `verifies` of its own
  #   * `:contained` — a claim with none of its own, where a claim inside it is `:verified`
  #   * `:unverified` — a claim with no `verifies`, own or inside
  #   * `:through_claims` — a container: its claims answer for themselves
  #   * `:excused`, `:deferred` — a classed unit with no claims inside (spec-unit classes,
  #     #257); a classed unit with claims inside reads as a container
  #
  # No credit moves upward (a unit's own `verifies` says nothing of the claims inside it)
  # and none moves into own text (a claim inside says nothing of the unit's other text).

  alias Surfex.Scan
  alias Surfex.Scan.Markdown

  @type verdict :: :verified | :contained | :unverified | :through_claims | :excused | :deferred

  @type t :: %{
          verdicts: %{String.t() => verdict},
          contained: [%{unit: String.t(), inside: [String.t()], location: map}],
          on_container: [%{test: String.t(), unit: String.t(), inside: [String.t()]}],
          containers: [%{unit: String.t(), claims: non_neg_integer, verified: non_neg_integer}],
          inside: %{String.t() => [String.t()]},
          own: %{String.t() => MapSet.t(String.t())}
        }

  # Whether a spec unit has no text of its own: a marked table, or a section or block whose
  # own text is empty. Hints, rules, rows and contracts are always claims.
  @spec container?(Scan.t()) :: boolean
  def container?(%Scan{kind: :spec, role: :table}), do: true

  def container?(%Scan{kind: :spec, role: role} = scan) when role in [:section, :block],
    do: Markdown.claimless?(scan)

  def container?(%Scan{kind: :spec}), do: false

  # The verdicts of every spec unit in `scans`, from `relations` (relation statuses), and
  # what reads them: the contained claims, the `verifies` aimed at a container, each
  # container's claims verified out of all, the claims inside each unit and each claim's
  # own verifying tests and checks (by label). A unit is inside what it sits in (`within`)
  # and, for a section, the section it sits under (`under`), at any depth. `classed` maps
  # a unit to the class its own text is given (`:excused` or `:deferred`, #257); `%{}`
  # until then. `label` names a verifier as derive's lists do. Linear: each unit's chain is
  # walked once.
  @spec index([Scan.t()], [map], (tuple -> String.t()), %{String.t() => :excused | :deferred}) ::
          t
  def index(scans, relations, label, classed \\ %{}) do
    spec = for %Scan{kind: :spec} = s <- scans, do: s
    # What a unit sits in: a block or hint its section or block, a section the section
    # it sits under.
    within =
      for %Scan{} = s <- spec,
          outer = s.within || s.under,
          outer != nil,
          into: %{},
          do: {s.id, outer}

    claim? = Map.new(spec, &{&1.id, not container?(&1) and not Map.has_key?(classed, &1.id)})

    # Each unit => the claims inside it, at any depth, sorted: no output depends on the
    # order of the scans.
    inside =
      for %Scan{id: id} <- spec,
          claim?[id],
          outer <- ancestors(id, within),
          reduce: %{} do
        acc -> Map.update(acc, outer, [id], &[id | &1])
      end
      |> Map.new(fn {unit, ids} -> {unit, Enum.sort(ids)} end)

    own =
      for %{type: :verifies, state: :current, relation: {_, {kind, _} = from, {:spec, unit}}} <-
            relations,
          kind in [:test, :check],
          reduce: %{} do
        acc -> Map.update(acc, unit, MapSet.new([label.(from)]), &MapSet.put(&1, label.(from)))
      end

    verified? = fn id -> claim?[id] == true and Map.has_key?(own, id) end

    verdicts =
      Map.new(spec, fn %Scan{id: id} = s ->
        claims = Map.get(inside, id, [])

        verdict =
          cond do
            Map.has_key?(classed, id) and claims == [] -> Map.fetch!(classed, id)
            not claim?[id] -> :through_claims
            verified?.(id) -> :verified
            Enum.any?(claims, verified?) -> :contained
            true -> :unverified
          end

        {s.id, verdict}
      end)

    by_id = Map.new(spec, &{&1.id, &1})

    contained =
      for %Scan{id: id, location: location} <- spec,
          verdicts[id] == :contained,
          do: %{unit: id, inside: Enum.filter(inside[id], verified?), location: location}

    on_container =
      for %{type: :verifies, state: state, relation: {_, {kind, _} = from, {:spec, unit}}} <-
            relations,
          kind in [:test, :check],
          state != :retired,
          Map.has_key?(by_id, unit),
          verdicts[unit] == :through_claims,
          do: %{test: label.(from), unit: unit, inside: Map.get(inside, unit, [])}

    containers =
      for %Scan{id: id} <- spec,
          verdicts[id] == :through_claims,
          claims = Map.get(inside, id, []),
          do: %{unit: id, claims: length(claims), verified: Enum.count(claims, verified?)}

    %{
      verdicts: verdicts,
      contained: Enum.sort_by(contained, & &1.unit),
      on_container: Enum.sort_by(on_container, &{&1.unit, &1.test}),
      containers: Enum.sort_by(containers, & &1.unit),
      inside: inside,
      own: own
    }
  end

  # Every unit `unit` sits inside, innermost first, not `unit` itself. A cycle can't come
  # from a scanner, but must end the walk rather than loop.
  defp ancestors(unit, within), do: ancestors(unit, within, [unit])

  defp ancestors(unit, within, seen) do
    case Map.fetch(within, unit) do
      {:ok, parent} ->
        if parent in seen, do: [], else: [parent | ancestors(parent, within, [parent | seen])]

      :error ->
        []
    end
  end
end
