defmodule Surfex.Record do
  @moduledoc """
  The recording commands' logic: from the scans and the log as they are, the entries to
  append. Pure; the Mix tasks read the scans and the log, and append what this returns.

  Every function returns `{:ok, [entry]}` or `{:error, reason}`. Nothing here edits or
  removes an entry. A new entry supersedes the old ones by naming them as parents.

  ## Ids

  An id is a scan id: `MyApp.Cart.add/2`, `spec.md#Carts/Adding items`. When the same id
  is scanned under two kinds, a `spec:`, `code:`, `test:` or `class:` prefix picks one. An id that isn't
  scanned is an error that names it, since relating what doesn't exist would be
  orphaned from the moment it was recorded.

  ## Who and when

  `meta` carries `:by`, `:commit` and optionally `:at` into every entry: who recorded it,
  HEAD at the time (context only), and when.
  """

  alias Surfex.{Scan, Status}
  alias Surfex.Log.Entry

  @type meta :: keyword

  @doc """
  Relates `from` and `to` as `type`, at their current hashes. For a directed type the
  order is from → to. Supersedes the relation's current tips, if any.

  Naming a pair validates nothing (§18). An `implements` or `excuses` relation is recorded
  as **proposed**, and so is a `verifies` relation unless the test's current version has
  failed in `opts[:evidence]`: then it is recorded on that run, basis `:evidence`, the
  process's "failing test, then the test relation". Structural relations (`refines`,
  `tests`, `depends_on`) record facts and carry no basis.
  """
  @spec relate([Scan.t()], [Entry.t()], String.t(), String.t(), atom, meta, keyword) ::
          {:ok, [Entry.t()]} | {:error, String.t()}
  def relate(scans, entries, from, to, type, meta, opts \\ []) do
    with {:ok, a} <- find(scans, from),
         {:ok, b} <- find(scans, to),
         basis = relate_basis(type, a, Keyword.get(opts, :evidence, [])),
         [a, b] = [end_(a), end_(b)],
         {:ok, entry} <-
           entry(:relate, type, [a, b], parents(entries, type, a, b), with_basis(meta, basis)) do
      {:ok, [entry]}
    end
  end

  defp relate_basis(type, _from, _evidence) when type in [:implements, :excuses], do: :proposed

  defp relate_basis(:verifies, %Scan{kind: :test} = test, evidence),
    do: if(red?(evidence, test), do: :evidence, else: :proposed)

  defp relate_basis(_type, _from, _evidence), do: nil

  # Whether the test's current version has failed in `evidence`.
  defp red?(evidence, %Scan{id: id, hash: hash}),
    do: Enum.any?(evidence, &(&1.test == id and &1.test_hash == hash and &1.result == :failed))

  defp with_basis(meta, nil), do: Keyword.delete(meta, :basis)
  defp with_basis(meta, basis), do: Keyword.put(meta, :basis, basis)

  @doc """
  Relates `from` and `to` as `type` when one of them doesn't exist yet: a **planned**
  relation, the intent recorded before the code (or the section) is written. A scanned end
  is recorded at its current hash and the unscanned one without a hash. `Surfex.Status`
  reports the relation as planned until the id appears, then as dangling until someone
  confirms it.

  The unscanned end's kind is its `spec:` or `code:` prefix, or `:spec` when the id has a
  `#`, and `:code` otherwise. `plausible?` is asked whether such an id could exist (a spec
  id in a known file, a code name of the scanner's shape), so a typo doesn't become a
  permanent plan. At least one end must be scanned: use `relate/6` when both are.
  """
  @spec plan(
          [Scan.t()],
          [Entry.t()],
          String.t(),
          String.t(),
          atom,
          (atom, String.t() -> boolean),
          meta
        ) :: {:ok, [Entry.t()]} | {:error, String.t()}
  def plan(scans, entries, from, to, type, plausible?, meta) do
    case {find(scans, from), find(scans, to)} do
      {{:ok, _}, {:ok, _}} ->
        {:error, "#{from} and #{to} are both scanned: relate them, nothing is planned"}

      {{:error, _}, {:error, _}} ->
        {:error, "neither #{from} nor #{to} is scanned: a planned relation needs one that is"}

      {a, b} ->
        with {:ok, a} <- planned_end(a, from, plausible?),
             {:ok, b} <- planned_end(b, to, plausible?),
             {:ok, entry} <-
               entry(
                 :relate,
                 type,
                 [a, b],
                 parents(entries, type, a, b),
                 with_basis(meta, relate_basis(type, nil, []))
               ) do
          {:ok, [entry]}
        end
    end
  end

  @doc """
  Confirms one relation, named by its ends and `type`, that is **dangling** or
  **proposed**: a `relate` at the current hashes, superseding its tip, with basis
  `:judgement` (§18). The note (`meta[:note]`) is required: it records what was judged.

  An `implements` relation is refused: code is validated by evidence
  (`confirm_by_evidence/4`) or a review (`validate/6`), never asserted. The judgement path
  is for what only a judgement can settle: a `verifies` relation after a spec rewording
  that changes no behaviour, an `excuses` relation, a structural relation after a change.
  Under `require_red: true` (`opts`, with `evidence:`), a `tests` relation is refused until
  its test's current version has discriminated.
  """
  @spec confirm([Scan.t()], [Entry.t()], String.t(), String.t(), atom, meta, keyword) ::
          {:ok, [Entry.t()]} | {:error, String.t()}
  def confirm(scans, entries, from, to, type, meta, opts \\ []) do
    note = meta[:note]

    cond do
      type == :implements ->
        {:error,
         "implements is validated by evidence or a review, never by hand: " <>
           "`mix surfex.confirm --evidence` or `mix surfex.validate`"}

      not (is_binary(note) and String.trim(note) != "") ->
        {:error, "a note is required: say what was judged"}

      true ->
        with {:ok, a} <- find_or_recorded(scans, entries, from),
             {:ok, b} <- find_or_recorded(scans, entries, to) do
          status = Status.derive(scans, entries)
          relation = Entry.relation(type, a, b)

          case Enum.find(status.relations, &(&1.relation == relation)) do
            %{state: state} = r when state in [:dangling, :proposed] ->
              with :ok <- red_first([r], status, opts),
                   do: confirm_each([r], status, with_basis(meta, :judgement))

            %{state: state} ->
              {:error,
               "the #{type} relation between #{from} and #{to} is #{state}: nothing to confirm"}

            nil ->
              {:error, "no #{type} relation between #{from} and #{to} in the log"}
          end
        end
    end
  end

  @doc """
  Retires the relation of `type` between `from` and `to`: an entry naming every tip as a
  parent, with the ends as the tip recorded them. An end need not still be scanned, since
  retiring is how an orphaned relation is put to rest.
  """
  @spec retire([Scan.t()], [Entry.t()], String.t(), String.t(), atom, meta) ::
          {:ok, [Entry.t()]} | {:error, String.t()}
  def retire(scans, entries, from, to, type, meta) do
    with {:ok, tips} <- tips(scans, entries, from, to, type) do
      [tip | _] = tips

      with {:ok, entry} <- entry(:retire, type, tip.ends, Enum.map(tips, & &1.id), meta),
           do: {:ok, [entry]}
    end
  end

  @doc """
  Moves every live relation of `old` onto `new`: a renamed heading, an anchor added, a
  section moved to another file. For each relation whose tip names `old`, it appends a
  `retire` of that relation and a `relate` of the same type with `new` in `old`'s place.
  Both carry a note naming the move unless `meta` has one. Nothing is rewritten: the old
  relation's history stays in the log, retired.

  The moved end is recorded at the hash **recorded for `old`**, not at `new`'s current
  hash, and the other end at its recorded hash too. A move carries a judgement across; it
  never makes one. If the text changed as it moved, or the other end changed, the moved
  relation is dangling and needs confirming like any other.

  `old` need not be scanned any more; `new` must be, as the same kind. A conflicted
  relation must be resolved first, and an `old` with no live relation is an error.
  """
  @spec move([Scan.t()], [Entry.t()], String.t(), String.t(), meta) ::
          {:ok, [Entry.t()]} | {:error, String.t()}
  def move(scans, entries, old, new, meta) do
    with {:ok, target} <- find(scans, new),
         {_kind, old_id} = split_kind(old),
         groups = live_groups(entries, target.kind, old_id),
         :ok <-
           if(groups == [],
             do: {:error, "no live relation names #{old}: nothing to move"},
             else: :ok
           ) do
      note = Keyword.get(meta, :note, "moved from #{old_id} to #{target.id}")
      meta = Keyword.put(meta, :note, note)

      Enum.reduce_while(groups, {:ok, []}, fn {relation, tips}, {:ok, acc} ->
        with [tip] <- tips,
             ends = Enum.map(tip.ends, &moved_end(&1, target, old_id)),
             {:ok, retired} <- entry(:retire, tip.type, tip.ends, [tip.id], with_basis(meta, nil)),
             # A move changes where a relation points, not what validates it (§18).
             {:ok, moved} <-
               entry(
                 :relate,
                 tip.type,
                 ends,
                 parents(entries ++ acc, tip.type, hd(ends), List.last(ends)),
                 with_basis(meta, tip.basis)
               ) do
          {:cont, {:ok, acc ++ [retired, moved]}}
        else
          [_, _ | _] ->
            {:halt, {:error, "#{inspect(relation)} is conflicted: resolve it before moving"}}

          error ->
            {:halt, error}
        end
      end)
    end
  end

  # Relations with an end `{kind, old_id}`, grouped with their tips, excluding retired ones.
  defp live_groups(entries, kind, old_id) do
    entries
    |> Enum.filter(fn e -> Enum.any?(e.ends, &(&1.kind == kind and &1.id == old_id)) end)
    |> Enum.group_by(&Entry.relation/1)
    |> Enum.map(fn {relation, _} -> {relation, Status.tips(entries, relation)} end)
    |> Enum.reject(fn {_relation, tips} -> match?([%Entry{op: :retire}], tips) end)
    |> Enum.sort()
  end

  defp moved_end(%{kind: kind, id: id} = end_, %Scan{kind: kind, id: new}, id),
    do: %{end_ | id: new}

  defp moved_end(end_, _target, _old), do: end_

  @doc """
  The confirmations test evidence (`Surfex.Evidence`) justifies, for every relation that
  dangles. **People or agents judge meaning, and evidence judges behaviour**:

    * `verifies` (test → spec) is never confirmed by evidence. Whether a test still
      expresses a requirement is a judgement: `confirm/4`.
    * A dangling `tests` relation (test → code) is confirmed when the test's current
      version has discriminated (it failed against one version of its code and passed
      against another, `Surfex.Evidence.discriminating?/3`) and its latest run passed
      against the code's current version.
    * A dangling `implements` relation (spec ↔ code) is then confirmed when a test with a
      current `verifies` relation to the spec unit, or to a block or hint inside it, has a
      current `tests` relation to the code, a version that discriminated, and a latest run
      that passed against the code's current version. When the **spec** side is what
      changed, the `verifies` must be to that exact unit: someone has judged that the test
      expresses the reworded requirement.

  Each entry records the evidence in its note. Returns `{:ok, []}` when nothing is
  justified, which is not an error: evidence confirms what it can.
  """
  @spec confirm_by_evidence([Scan.t()], [Entry.t()], [Surfex.Evidence.t()], meta) ::
          {:ok, [Entry.t()]} | {:error, String.t()}
  def confirm_by_evidence(scans, entries, evidence, meta) do
    meta = with_basis(meta, :evidence)
    status = Status.derive(scans, entries)

    with {:ok, verifies} <-
           by_evidence(status, :verifies, &verifies_evidence(&1, status, evidence), meta),
         status = Status.derive(scans, entries ++ verifies),
         {:ok, tests} <- by_evidence(status, :tests, &tests_evidence(&1, status, evidence), meta) do
      status = Status.derive(scans, entries ++ verifies ++ tests)

      implemented =
        by_evidence(status, :implements, &implements_evidence(&1, status, evidence), meta)

      with {:ok, implements} <- implemented, do: {:ok, verifies ++ tests ++ implements}
    end
  end

  # A verifies relation on its failing run: the test's current version has failed, so it
  # is live and tests something the code didn't do (§18). When only the spec end changed,
  # a failing run says nothing about the rewording: that is the judgement path.
  defp verifies_evidence(%{relation: {:verifies, {:test, t}, {:spec, _}}} = r, status, evidence) do
    test = Map.fetch!(status.scans, {:test, t})
    spec_only? = r.changed != [] and {:test, t} not in r.changed

    with false <- spec_only?,
         %{} = red <-
           Enum.find(
             evidence,
             &(&1.test == t and &1.test_hash == test.hash and &1.result == :failed)
           ) do
      "#{Surfex.Evidence.note()}: #{t}@#{test.hash} failed at #{red.at}, the test relation on its failing run"
    else
      _ -> nil
    end
  end

  # For each dangling relation of `type` the evidence justifies (`why` gives a note or
  # nil), a relate at the current versions.
  defp by_evidence(status, type, why, meta) do
    Enum.reduce_while(status.relations, {:ok, []}, fn
      %{type: ^type, state: state, tips: [tip]} = r, {:ok, acc}
      when state in [:dangling, :proposed] ->
        case why.(r) do
          nil ->
            {:cont, {:ok, acc}}

          note ->
            ends = Enum.map(tip.ends, &end_(Map.fetch!(status.scans, {&1.kind, &1.id})))

            case entry(:relate, type, ends, [tip.id], Keyword.put(meta, :note, note)) do
              {:ok, e} -> {:cont, {:ok, acc ++ [e]}}
              error -> {:halt, error}
            end
        end

      _other, acc ->
        {:cont, acc}
    end)
  end

  # A tests relation: the test's current version discriminated, and its latest run passed
  # against the code's current version.
  defp tests_evidence(%{relation: {:tests, {:test, t}, {:code, c}}}, status, evidence) do
    test = Map.fetch!(status.scans, {:test, t})
    code = Map.fetch!(status.scans, {:code, c})
    green_against(evidence, test, code, definitions(status))
  end

  # code id => its definition (`Surfex.Scan.definition/1`): one function's default arities
  # are one code.
  defp definitions(status) do
    fn id ->
      case Map.get(status.scans, {:code, id}) do
        nil -> {:code, id}
        scan -> Scan.definition(scan)
      end
    end
  end

  defp green_against(evidence, test, code, definition) do
    with {red, green} <- Surfex.Evidence.red_then_green(evidence, test.id, test.hash),
         %{result: :passed, code: versions} = latest <-
           Surfex.Evidence.latest(evidence, test.id, test.hash),
         true <-
           Enum.any?(versions, fn {id, h} ->
             h == code.hash and definition.(id) == Scan.definition(code)
           end) do
      "#{Surfex.Evidence.note()}: #{test.id}@#{test.hash} failed at #{red.at} (#{versions_text(red)}) " <>
        "and passes at #{latest.at} against #{code.id}@#{code.hash}" <>
        if(green != latest, do: " (first green #{green.at})", else: "")
    else
      _ -> nil
    end
  end

  defp versions_text(%{code: versions}) when map_size(versions) == 0, do: "no code yet"

  defp versions_text(%{code: versions}),
    do: versions |> Enum.sort() |> Enum.map_join(", ", fn {id, h} -> "#{id}@#{h}" end)

  # An implements relation: some test verifying the spec unit (exactly, when the spec is
  # what changed) and exercising the code, with evidence green against the code now.
  defp implements_evidence(
         %{relation: {:implements, {:code, c}, {:spec, s}}} = r,
         status,
         evidence
       ) do
    code = Map.fetch!(status.scans, {:code, c})
    spec_changed? = {:spec, s} in r.changed

    # Only a validated test relation carries the code relation: an unvalidated one is a
    # claim, and code derived from a claim would be a guess again (§18).
    live = fn type ->
      for %{type: ^type, state: :current, tips: [tip], relation: {_, a, b}} <- status.relations,
          type != :verifies or validated?(tip),
          do: {a, b}
    end

    verifying =
      for {{:test, t}, {:spec, unit}} <- live.(:verifies),
          if(spec_changed?, do: unit == s, else: inside?(unit, s, status.scans)),
          uniq: true,
          do: t

    definition = definitions(status)

    exercising =
      MapSet.new(
        for {{:test, t}, {:code, other}} <- live.(:tests),
            definition.(other) == Scan.definition(code),
            do: t
      )

    Enum.find_value(verifying, fn t ->
      if MapSet.member?(exercising, t) do
        case green_against(evidence, Map.fetch!(status.scans, {:test, t}), code, definition) do
          nil -> nil
          note -> "#{note}; #{t} verifies #{s}"
        end
      end
    end)
  end

  defp validated?(%Entry{basis: basis}), do: basis in [:evidence, :review, :judgement]

  @doc """
  Records a **review** (§18): `test` was examined against `unit` and judged to validate
  it, and it passes against the code. It is how a relation made before validation existed
  gets validated, by doing the work rather than asserting it.

  It needs a live `verifies` relation from the test to the unit, and green evidence for
  the test's current version (its latest run passed). It records that `verifies` relation,
  and each live `implements` relation of the unit, not validated already, whose code the
  test's latest run exercised at its current version, at the current hashes with basis `:review`. The note
  (`meta[:note]`) is required: it says which claim each assertion checks. One test and one
  unit per call.

  The unit may be a section whose block or hint the test verifies, since code implements
  the section while its tests verify what is inside it. The test's relation to that inner
  unit must already be validated (reviewed against it first), and only the section's
  `implements` relations are recorded.
  """
  @spec validate([Scan.t()], [Entry.t()], String.t(), String.t(), [Surfex.Evidence.t()], meta) ::
          {:ok, [Entry.t()]} | {:error, String.t()}
  def validate(scans, entries, test_id, unit_id, evidence, meta) do
    note = meta[:note]
    status = Status.derive(scans, entries)
    meta = with_basis(meta, :review)

    with :ok <-
           if(is_binary(note) and String.trim(note) != "",
             do: :ok,
             else: {:error, "a note is required: say which claim each assertion checks"}
           ),
         {:ok, test} <- find(scans, "test:" <> strip_kind(test_id)),
         {:ok, unit} <- find(scans, "spec:" <> strip_kind(unit_id)),
         {:ok, reviewed} <- reviewed(status, test, unit),
         {:ok, green} <- green_run(evidence, test) do
      # What the run exercised at its current version, by definition: a function's default
      # arities are one code (§11), as they are for evidence.
      ran =
        MapSet.new(
          for {id, hash} <- green.code,
              scan = Map.get(status.scans, {:code, id}),
              scan != nil and scan.hash == hash,
              do: Scan.definition(scan)
        )

      exercised = &MapSet.member?(ran, Scan.definition(&1))
      spec_id = unit.id

      implements =
        for %{type: :implements, state: state, relation: {_, {:code, c}, {:spec, ^spec_id}}} = r <-
              status.relations,
            state not in [:retired, :orphaned, :planned, :conflicted],
            not (state == :current and validated?(hd(r.tips))),
            code = Map.fetch!(status.scans, {:code, c}),
            exercised.(code),
            do: r

      confirm_each(reviewed ++ implements, status, meta)
    end
  end

  # What the review records besides the unit's code: the test's relation to the unit
  # itself, or nothing when the test verifies a unit inside it whose relation is already
  # validated (§18).
  defp reviewed(status, test, unit) do
    missing = "no verifies relation from #{test.id} to #{unit.id} or a unit inside it"

    case live_relation(status, Entry.relation(:verifies, end_(test), end_(unit)), missing) do
      {:ok, direct} ->
        {:ok, [direct]}

      {:error, _} ->
        inner =
          for %{type: :verifies, relation: {_, {:test, t}, {:spec, s}}} = r <- status.relations,
              t == test.id,
              s != unit.id,
              r.state not in [:retired, :orphaned],
              inside?(s, unit.id, status.scans),
              do: r

        cond do
          inner == [] ->
            {:error, missing}

          Enum.any?(inner, &(&1.state == :current and validated?(hd(&1.tips)))) ->
            {:ok, []}

          true ->
            %{relation: {_, _, {:spec, s}}} = hd(inner)
            {:error, "validate #{test.id} against #{s} first: its relation there isn't validated"}
        end
    end
  end

  defp live_relation(status, relation, missing) do
    case Enum.find(status.relations, &(&1.relation == relation)) do
      %{state: state} = r when state not in [:retired, :orphaned, :conflicted] -> {:ok, r}
      _ -> {:error, missing}
    end
  end

  defp green_run(evidence, test) do
    case Surfex.Evidence.latest(evidence, test.id, test.hash) do
      %{result: :passed} = green -> {:ok, green}
      _ -> {:error, "no green run of #{test.id} at its current version: run the tests first"}
    end
  end

  defp inside?(unit, unit, _scans), do: true

  defp inside?(unit, spec, scans) do
    case Map.get(scans, {:spec, unit}) do
      %Scan{within: nil} -> false
      %Scan{within: parent} -> inside?(parent, spec, scans)
      nil -> false
    end
  end

  @doc """
  Resolves a conflicted relation: the tip whose id starts with `pick` is recorded again
  with every tip as a parent. The relation is then judged by that entry. If the scans have
  moved since, it is dangling, and `confirm/4` is next.
  """
  @spec resolve([Scan.t()], [Entry.t()], String.t(), String.t(), atom, String.t(), meta) ::
          {:ok, [Entry.t()]} | {:error, String.t()}
  def resolve(scans, entries, from, to, type, pick, meta) do
    with {:ok, tips} <- tips(scans, entries, from, to, type),
         :ok <-
           if(length(tips) > 1,
             do: :ok,
             else: {:error, "the #{type} relation is not conflicted: nothing to resolve"}
           ),
         {:ok, chosen} <- choose(tips, pick),
         {:ok, entry} <-
           entry(chosen.op, type, chosen.ends, Enum.map(tips, & &1.id), meta, chosen.note) do
      {:ok, [entry]}
    end
  end

  @doc "Every entry with an end whose id is `id`, oldest first."
  @spec history([Entry.t()], String.t()) :: [Entry.t()]
  def history(entries, id) do
    bare = strip_kind(id)

    entries
    |> Enum.filter(fn e -> Enum.any?(e.ends, &(&1.id == bare)) end)
    |> Enum.sort_by(&{&1.at, &1.id})
  end

  # ── Pieces ──────────────────────────────────────────────────────────────

  defp confirm_each(dangling, status, meta) do
    Enum.reduce_while(dangling, {:ok, []}, fn r, {:ok, acc} ->
      [tip] = r.tips

      ends = Enum.map(tip.ends, fn e -> end_(Map.fetch!(status.scans, {e.kind, e.id})) end)

      case entry(:relate, r.type, ends, [tip.id], meta) do
        {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
        error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, list} -> {:ok, Enum.reverse(list)}
      error -> error
    end)
  end

  defp red_first(dangling, status, opts) do
    if Keyword.get(opts, :require_red, false) do
      evidence = Keyword.get(opts, :evidence, [])

      never_red =
        for %{type: :tests, relation: {_, {:test, t}, _}} <- dangling,
            test = Map.fetch!(status.scans, {:test, t}),
            not Surfex.Evidence.discriminating?(evidence, test.id, test.hash),
            uniq: true,
            do: t

      if never_red == [],
        do: :ok,
        else:
          {:error,
           "require_red: #{Enum.join(never_red, ", ")} has never failed at its current version"}
    else
      :ok
    end
  end

  defp tips(scans, entries, from, to, type) do
    with {:ok, a} <- find_or_recorded(scans, entries, from),
         {:ok, b} <- find_or_recorded(scans, entries, to) do
      case Status.tips(entries, Entry.relation(type, a, b)) do
        [] -> {:error, "no #{type} relation between #{from} and #{to} in the log"}
        tips -> {:ok, tips}
      end
    end
  end

  # An end for a relation that may already be orphaned: the scan if there is one, else the
  # last recorded form of that id.
  defp find_or_recorded(scans, entries, id) do
    case find(scans, id) do
      {:ok, scan} ->
        {:ok, end_(scan)}

      {:error, _} = error ->
        bare = strip_kind(id)

        case entries
             |> Enum.flat_map(& &1.ends)
             |> Enum.filter(&(&1.id == bare))
             |> List.last() do
          nil -> error
          recorded -> {:ok, recorded}
        end
    end
  end

  defp choose(tips, pick) do
    case Enum.filter(tips, &String.starts_with?(&1.id, pick)) do
      [one] ->
        {:ok, one}

      [] ->
        {:error,
         "no tip's id starts with #{pick}; the tips are #{Enum.map_join(tips, ", ", &String.slice(&1.id, 0, 12))}"}

      _ ->
        {:error, "#{pick} names more than one tip; give more of the id"}
    end
  end

  defp planned_end({:ok, scan}, _id, _plausible?), do: {:ok, end_(scan)}

  defp planned_end({:error, _}, id, plausible?) do
    {kind, bare} =
      case split_kind(id) do
        {nil, bare} -> {if(String.contains?(bare, "#"), do: :spec, else: :code), bare}
        known -> known
      end

    if plausible?.(kind, bare),
      do: {:ok, %{kind: kind, id: bare, hash: nil}},
      else:
        {:error,
         "#{id} is not scanned and doesn't look like a #{kind} id this project could have: check it for a typo"}
  end

  defp parents(entries, type, a, b) do
    entries |> Status.tips(Entry.relation(type, a, b)) |> Enum.map(& &1.id)
  end

  defp entry(op, type, ends, parents, meta, note \\ nil) do
    Entry.build(
      at:
        Keyword.get_lazy(meta, :at, fn ->
          DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
        end),
      commit: meta[:commit],
      by: meta[:by],
      note: Keyword.get(meta, :note, note),
      op: op,
      type: type,
      parents: parents,
      ends: ends,
      basis: meta[:basis]
    )
  end

  defp end_(%Scan{kind: kind, id: id, hash: hash}), do: %{kind: kind, id: id, hash: hash}

  # ── Ids ─────────────────────────────────────────────────────────────────

  defp find(scans, id) do
    {kind, bare} = split_kind(id)

    case Enum.filter(scans, &(&1.id == bare and (kind == nil or &1.kind == kind))) do
      [scan] ->
        {:ok, scan}

      [] ->
        {:error, "#{id} is not scanned: no spec section or code item has that id"}

      several ->
        if kind == nil and length(Enum.uniq_by(several, & &1.kind)) > 1,
          do:
            {:error,
             "#{id} is scanned as more than one kind; prefix it with spec:, code:, test: or class:"},
          else: {:error, "#{id} names #{length(several)} scanned records of one kind"}
    end
  end

  defp split_kind("spec:" <> rest), do: {:spec, rest}
  defp split_kind("code:" <> rest), do: {:code, rest}
  defp split_kind("test:" <> rest), do: {:test, rest}
  defp split_kind("class:" <> rest), do: {:class, rest}
  defp split_kind(id), do: {nil, id}

  defp strip_kind(id), do: id |> split_kind() |> elem(1)
end
