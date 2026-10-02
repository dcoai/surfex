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

  # A planned verifies has no test that could have failed yet: it is a claim.
  defp relate_basis(:verifies, _from, _evidence), do: :proposed
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
  Records a mark of `type` (`:needs_update`, §12.1) on one spec unit, at its current
  version: the spec itself needs to change, because the tests reflect it and the code
  passes them but the result is wrong or clearly sub-optimal. `meta[:note]` is required: it
  says what is wrong in the result.
  """
  @spec mark([Scan.t()], [Entry.t()], String.t(), atom, meta) ::
          {:ok, [Entry.t()]} | {:error, String.t()}
  def mark(scans, _entries, unit_id, type, meta) do
    with :ok <- note!(meta, "say what is wrong in the result"),
         {:ok, unit} <- spec_unit(scans, unit_id),
         {:ok, entry} <- entry(:mark, type, [end_(unit)], [], meta),
         do: {:ok, [entry]}
  end

  @doc """
  Withdraws the open mark of `type` on a spec unit: a retire naming it as its parent, with
  `meta[:note]` (required) saying why it proved unfounded. With several open marks,
  `meta[:pick]`, a prefix of one's id, names it.
  """
  @spec withdraw([Scan.t()], [Entry.t()], String.t(), atom, meta) ::
          {:ok, [Entry.t()]} | {:error, String.t()}
  def withdraw(scans, entries, unit_id, type, meta) do
    with :ok <- note!(meta, "say why the mark proved unfounded"),
         {:ok, unit} <- spec_unit(scans, unit_id),
         {:ok, mark} <- open_mark(scans, entries, unit.id, type, meta[:pick]),
         {:ok, entry} <- entry(:retire, type, mark.ends, [mark.id], meta),
         do: {:ok, [entry]}
  end

  @doc """
  Takes the one-shot baseline (§18.1) under `meta[:adoption]` (`Surfex.Status.Config.adoption!/2`):
  a `baseline` observation for each trusted test version, and a `verifies` relation with
  basis `:baseline` for each of its declarations, so the existing suite counts as if it had
  discriminated. `meta[:note]` is required: it says why the suite is trusted.

  It refuses under `:reevaluate`, when the log already holds a baseline, when no tests are
  scanned, and when a trusted test's current version hasn't run green in `evidence`.
  """
  @spec baseline([Scan.t()], [Entry.t()], [Surfex.Evidence.t()], meta) ::
          {:ok, [Entry.t()]} | {:error, String.t()}
  def baseline(scans, entries, evidence, meta) do
    adoption = Keyword.fetch!(meta, :adoption)
    tests = for %Scan{kind: :test} = t <- scans, do: t
    trusted = Enum.filter(tests, &Surfex.Status.Config.trusted?(adoption, &1.location.file))

    not_green =
      for t <- trusted,
          not match?(%{result: :passed}, Surfex.Evidence.latest(evidence, t.id, t.hash)),
          do: t.id

    taken = Enum.find(entries, &match?(%Entry{op: :observe, type: :baseline}, &1))

    with :ok <- note!(meta, "say why the existing suite is trusted"),
         :ok <-
           if(adoption.setting == :reevaluate,
             do:
               {:error,
                "adoption: is :reevaluate, so nothing is trusted: set adoption: :trust " <>
                  "(or trusted globs) in .surfex.exs to take a baseline"},
             else: :ok
           ),
         :ok <-
           if(taken,
             do:
               {:error,
                "a baseline was already taken (entry #{String.slice(taken.id, 0, 12)}): it is one-shot"},
             else: :ok
           ),
         :ok <-
           if(tests == [],
             do: {:error, "no tests are scanned: set tests: in .surfex.exs"},
             else: :ok
           ),
         :ok <- if(not_green == [], do: :ok, else: {:error, not_green_message(not_green)}),
         :ok <- tags!(scans, trusted, meta) do
      note = "baseline under adoption: #{inspect(adoption.setting)}: #{meta[:note]}"

      meta =
        meta |> Keyword.delete(:adoption) |> Keyword.put(:note, note) |> with_basis(:baseline)

      status = Status.derive(scans, entries)

      trusted
      |> Enum.flat_map(fn test ->
        observation = entry(:observe, :baseline, [end_(test)], [], meta)

        verifies =
          for {:verifies, ref} <- test.declares,
              {:ok, unit} <- [Scan.resolve(scans, ref)],
              relation = Entry.relation(:verifies, end_(test), end_(unit)),
              do:
                entry(
                  :relate,
                  :verifies,
                  [end_(test), end_(unit)],
                  tip_ids(status, relation),
                  meta
                )

        [observation | verifies]
      end)
      |> Enum.reduce_while({:ok, []}, fn
        {:ok, e}, {:ok, acc} -> {:cont, {:ok, acc ++ [e]}}
        error, _acc -> {:halt, error}
      end)
    end
  end

  # The baseline adopts the verifies: tags already written, once: adopting none would spend
  # it on test versions alone, so that takes saying so (§18.1).
  defp tags!(scans, trusted, meta) do
    tagged = Enum.any?(trusted, &(declared_units(scans, &1) != []))

    if tagged or meta[:no_tags] == true,
      do: :ok,
      else:
        {:error,
         "the trusted tests declare no verifies: tags, so the baseline would adopt none, and it " <>
           "is one-shot. Tag the tests that verify each spec unit first (mix surfex.info " <>
           "adoption), or pass --no-tags to baseline the test versions alone and tag later, " <>
           "each tag then validated on its own"}
  end

  defp declared_units(scans, test),
    do:
      for({:verifies, ref} <- test.declares, {:ok, unit} <- [Scan.resolve(scans, ref)], do: unit)

  @doc """
  What a baseline (`baseline/4`) adopted, from the entries it recorded: the trusted test
  versions, the `verifies` relations, and the spec units no adopted `verifies` reaches
  (directly, or through a unit inside them).
  """
  @spec baseline_summary([Scan.t()], [Entry.t()]) :: %{
          trusted: non_neg_integer,
          verifies: non_neg_integer,
          units_without: non_neg_integer
        }
  def baseline_summary(scans, recorded) do
    within = for %Scan{kind: :spec, within: w} = s <- scans, w != nil, into: %{}, do: {s.id, w}

    verified =
      for %Entry{op: :relate, type: :verifies, ends: ends} <- recorded,
          %{kind: :spec, id: id} <- ends,
          unit <- outward(id, within),
          into: MapSet.new(),
          do: unit

    %{
      trusted: Enum.count(recorded, &match?(%Entry{op: :observe, type: :baseline}, &1)),
      verifies: Enum.count(recorded, &match?(%Entry{op: :relate, type: :verifies}, &1)),
      units_without:
        Enum.count(scans, &(&1.kind == :spec and not MapSet.member?(verified, &1.id)))
    }
  end

  # A unit and every unit it sits inside.
  defp outward(id, within) do
    case Map.get(within, id) do
      nil -> [id]
      parent -> [id | outward(parent, within)]
    end
  end

  defp not_green_message([one]),
    do: "1 trusted test hasn't run green at its current version: run the tests first (#{one})"

  defp not_green_message(many),
    do:
      "#{length(many)} trusted tests haven't run green at their current versions: " <>
        "run the tests first (#{Enum.join(Enum.take(many, 5), ", ")}…)"

  defp tip_ids(status, relation) do
    case Enum.find(status.relations, &(&1.relation == relation)) do
      nil -> []
      r -> Enum.map(r.tips, & &1.id)
    end
  end

  defp note!(meta, what) do
    if is_binary(meta[:note]) and String.trim(meta[:note]) != "",
      do: :ok,
      else: {:error, "a note is required: #{what}"}
  end

  defp spec_unit(scans, id) do
    case find(scans, id) do
      {:ok, %Scan{kind: :spec} = unit} -> {:ok, unit}
      {:ok, %Scan{id: id}} -> {:error, "#{id} is not a spec unit: only a spec unit is marked"}
      error -> error
    end
  end

  defp open_mark(scans, entries, unit, type, pick) do
    open =
      for %{id: id, unit: ^unit, type: ^type} <- Status.derive(scans, entries).marks,
          mark = Enum.find(entries, &(&1.id == id)),
          do: mark

    case {open, pick} do
      {[], _} ->
        {:error, "no open #{type} mark on #{unit}"}

      {[one], nil} ->
        {:ok, one}

      {many, nil} ->
        ids = Enum.map_join(many, ", ", &String.slice(&1.id, 0, 12))
        {:error, "#{length(many)} open #{type} marks on #{unit} (#{ids}): name one with pick"}

      {many, pick} ->
        case Enum.filter(many, &String.starts_with?(&1.id, pick)) do
          [one] -> {:ok, one}
          _ -> {:error, "no single open #{type} mark on #{unit} starts with #{pick}"}
        end
    end
  end

  @doc """
  Retires the relation of `type` between `from` and `to`: an entry naming every tip as a
  parent, with the ends as the tip recorded them. An end need not still be scanned, since
  retiring is how an orphaned relation is put to rest.

  A pair **never related** can be retired too: that declines it, recording the decision
  not to relate them before anyone has (§14). Both must be scanned, the entry is at their
  current versions with no parent, and `meta[:note]` is required: it is the only record of
  why. `Surfex.Suggest` then never proposes the pair, and a later `relate/6` revives it.
  """
  @spec retire([Scan.t()], [Entry.t()], String.t(), String.t(), atom, meta) ::
          {:ok, [Entry.t()]} | {:error, String.t()}
  def retire(scans, entries, from, to, type, meta) do
    with {:ok, a} <- find_or_recorded(scans, entries, from),
         {:ok, b} <- find_or_recorded(scans, entries, to) do
      case Status.tips(entries, Entry.relation(type, a, b)) do
        [] ->
          decline(scans, from, to, type, meta)

        [tip | _] = tips ->
          with {:ok, entry} <- entry(:retire, type, tip.ends, Enum.map(tips, & &1.id), meta),
               do: {:ok, [entry]}
      end
    end
  end

  # A retire of a pair the log has never related: the decision not to relate it.
  defp decline(scans, from, to, type, meta) do
    with {:ok, a} <- find(scans, from),
         {:ok, b} <- find(scans, to),
         :ok <-
           if(is_binary(meta[:note]) and String.trim(meta[:note]) != "",
             do: :ok,
             else:
               {:error,
                "#{from} and #{to} were never related as #{type}: declining them needs a note " <>
                  "saying why (--note)"}
           ),
         {:ok, entry} <- entry(:retire, type, [end_(a), end_(b)], [], with_basis(meta, nil)) do
      {:ok, [entry]}
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
  relation must be resolved first, and an `old` with nothing to move is an error.

  **A test's records come too** (§14). A test's version is its content, not its name, so a
  renamed module, `describe` or file is the same version under a new id. Each `red_green`
  and `baseline` observation of `old` at the version `new` is scanned at is recorded again
  on `new`, with its type and basis and a note naming the original. One at another
  version stays behind (`left_behind/4`): the test changed, and earns its records again.
  """
  @spec move([Scan.t()], [Entry.t()], String.t(), String.t(), meta) ::
          {:ok, [Entry.t()]} | {:error, String.t()}
  def move(scans, entries, old, new, meta) do
    with {:ok, target} <- find(scans, new),
         {_kind, old_id} = split_kind(old),
         groups = live_groups(entries, target.kind, old_id),
         retirements = retirements(entries, target, old_id),
         {carry, _left} = test_observations(entries, target, old_id),
         :ok <-
           if(groups == [] and retirements == [] and carry == [],
             do: {:error, "no live relation names #{old}: nothing to move"},
             else: :ok
           ) do
      note = Keyword.get(meta, :note, "moved from #{old_id} to #{target.id}")
      meta = Keyword.put(meta, :note, note)

      with {:ok, moved} <- move_relations(groups, entries, target, old_id, meta),
           {:ok, kept} <- carry_retirements(retirements, meta),
           {:ok, carried} <- carry(carry, target, old_id, meta),
           do: {:ok, moved ++ kept ++ carried}
    end
  end

  @doc """
  The observations of test `old` that a move to `new` leaves behind (`move/5`): those at a
  version other than the one `new` is scanned at, each with its type, the version it was
  for (`hash`) and `new`'s (`now`).
  """
  @spec left_behind([Scan.t()], [Entry.t()], String.t(), String.t()) :: [
          %{type: atom, hash: String.t(), now: String.t(), entry: String.t()}
        ]
  def left_behind(scans, entries, old, new) do
    {:ok, target} = find(scans, new)
    {_kind, old_id} = split_kind(old)
    {_carry, left} = test_observations(entries, target, old_id)
    for e <- left, do: %{type: e.type, hash: hd(e.ends).hash, now: target.hash, entry: e.id}
  end

  # A test's observations under `old_id`: those at `target`'s version, not already on
  # `target`, to carry; those at another version, left behind.
  defp test_observations(entries, %Scan{kind: :test} = target, old_id) do
    mine = for %Entry{op: :observe, ends: [%{id: ^old_id}]} = e <- entries, do: e

    have =
      MapSet.new(
        for %Entry{op: :observe, ends: [%{id: id, hash: h}]} = e <- entries,
            id == target.id,
            do: {e.type, h}
      )

    {carry, left} = Enum.split_with(mine, &(hd(&1.ends).hash == target.hash))
    {Enum.reject(carry, &MapSet.member?(have, {&1.type, target.hash})), left}
  end

  defp test_observations(_entries, _target, _old_id), do: {[], []}

  defp carry(observations, target, old_id, meta) do
    Enum.reduce_while(observations, {:ok, []}, fn e, {:ok, acc} ->
      note = "#{meta[:note]}; carried from #{old_id} (entry #{String.slice(e.id, 0, 12)})"
      meta = meta |> Keyword.put(:note, note) |> with_basis(e.basis)

      case entry(:observe, e.type, [%{kind: :test, id: target.id, hash: target.hash}], [], meta) do
        {:ok, carried} -> {:cont, {:ok, acc ++ [carried]}}
        error -> {:halt, error}
      end
    end)
  end

  defp move_relations(groups, entries, target, old_id, meta) do
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

  # The retired relations of `old_id` whose moved relation the log doesn't have yet: a
  # retirement is a decision, carried as one, and never over a relation the new id has.
  defp retirements(entries, target, old_id) do
    known = MapSet.new(for e <- entries, Entry.relation?(e), do: Entry.relation(e))

    for %Entry{op: :retire} = tip <- retired_tips(entries, target.kind, old_id),
        ends = Enum.map(tip.ends, &moved_end(&1, target, old_id)),
        not MapSet.member?(known, Entry.relation(tip.type, hd(ends), List.last(ends))),
        do: {tip, ends}
  end

  defp carry_retirements(retirements, meta) do
    Enum.reduce_while(retirements, {:ok, []}, fn {tip, ends}, {:ok, acc} ->
      reason = if tip.note, do: ": #{tip.note}", else: ""
      note = "#{meta[:note]}; still retired (entry #{String.slice(tip.id, 0, 12)})#{reason}"

      case entry(:retire, tip.type, ends, [], meta |> Keyword.put(:note, note) |> with_basis(nil)) do
        {:ok, kept} -> {:cont, {:ok, acc ++ [kept]}}
        error -> {:halt, error}
      end
    end)
  end

  defp retired_tips(entries, kind, old_id) do
    entries
    |> Enum.filter(&Entry.relation?/1)
    |> Enum.filter(fn e -> Enum.any?(e.ends, &(&1.kind == kind and &1.id == old_id)) end)
    |> Enum.map(&Entry.relation/1)
    |> Enum.uniq()
    |> Enum.flat_map(fn relation ->
      case Status.tips(entries, relation) do
        [%Entry{op: :retire} = tip] -> [tip]
        _ -> []
      end
    end)
  end

  # Relations with an end `{kind, old_id}`, grouped with their tips, excluding retired ones.
  defp live_groups(entries, kind, old_id) do
    entries
    # Marks and observations aren't relations: a move carries relations only (§14).
    |> Enum.filter(&Entry.relation?/1)
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
  dangles or is proposed, basis `:evidence` (§17, §18). **People or agents judge meaning,
  and evidence judges behaviour**:

    * First, each test version that has discriminated in the evidence and has no record
      in the log yet gets one: a `red_green` observation (§12.1), so the fact outlives the
      evidence file.
    * A `verifies` relation (test → spec) is recorded on its failing run: the test's
      current version has failed. When only the spec changed, a failing run says nothing
      about the rewording: that is a judgement, `confirm/6`.
    * A dangling `tests` relation (test → code) is confirmed when the test's current
      version has discriminated (it failed against one version of its code and passed
      against another, `Surfex.Evidence.discriminating?/3`, or the log holds its
      `red_green` observation) and its latest run passed against the code's current
      version.
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
    # Under the project's adoption: setting (§18.1), a baselined test counts as discriminated.
    derive = &Status.derive(scans, &1, [], Keyword.take(meta, [:adoption]))
    meta = meta |> Keyword.delete(:adoption) |> with_basis(:evidence)
    status = derive.(entries)

    with {:ok, observed} <- observations(status, evidence, meta),
         {:ok, verifies} <-
           by_evidence(status, :verifies, &verifies_evidence(&1, status, evidence), meta),
         status = derive.(entries ++ verifies),
         {:ok, tests} <- by_evidence(status, :tests, &tests_evidence(&1, status, evidence), meta) do
      status = derive.(entries ++ verifies ++ tests)

      implemented =
        by_evidence(status, :implements, &implements_evidence(&1, status, evidence), meta)

      with {:ok, implements} <- implemented,
           do: {:ok, observed ++ verifies ++ tests ++ implements}
    end
  end

  # A red_green observation for each scanned test version that discriminated in the
  # evidence and that the log doesn't record yet (§17).
  defp observations(status, evidence, meta) do
    Enum.reduce_while(Enum.sort(Map.keys(status.scans)), {:ok, []}, fn
      {:test, _} = key, {:ok, acc} ->
        test = Map.fetch!(status.scans, key)

        with false <- MapSet.member?(status.discriminated, {test.id, test.hash}),
             {red, green} <- Surfex.Evidence.red_then_green(evidence, test.id, test.hash) do
          note =
            "#{Surfex.Evidence.note()}: #{test.id}@#{test.hash} failed at #{red.at} " <>
              "(#{versions_text(red)}) and passed at #{green.at} (#{versions_text(green)})"

          case entry(:observe, :red_green, [end_(test)], [], Keyword.put(meta, :note, note)) do
            {:ok, e} -> {:cont, {:ok, acc ++ [e]}}
            error -> {:halt, error}
          end
        else
          _ -> {:cont, {:ok, acc}}
        end

      _key, acc ->
        {:cont, acc}
    end)
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

          justified ->
            # A note, or a note with its own basis (a baselined test's, §18.1).
            {note, meta} =
              case justified do
                {note, basis} -> {note, with_basis(meta, basis)}
                note -> {note, meta}
              end

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
    green_against(evidence, status, test, code, definitions(status))
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

  # The test's latest run passed against the code's current version, and its version has
  # discriminated: in the evidence, or by the log's record when the evidence is gone.
  defp green_against(evidence, status, test, code, definition) do
    with %{result: :passed, code: versions} = latest <-
           Surfex.Evidence.latest(evidence, test.id, test.hash),
         true <-
           Enum.any?(versions, fn {id, h} ->
             h == code.hash and definition.(id) == Scan.definition(code)
           end) do
      passes = "passes at #{latest.at} against #{code.id}@#{code.hash}"

      case Surfex.Evidence.red_then_green(evidence, test.id, test.hash) do
        {red, green} ->
          "#{Surfex.Evidence.note()}: #{test.id}@#{test.hash} failed at #{red.at} (#{versions_text(red)}) " <>
            "and #{passes}" <> if(green != latest, do: " (first green #{green.at})", else: "")

        nil ->
          cond do
            MapSet.member?(status.discriminated, {test.id, test.hash}) ->
              "#{Surfex.Evidence.note()}: #{test.id}@#{test.hash} discriminated (recorded in the log) " <>
                "and #{passes}"

            MapSet.member?(status.baselined, {test.id, test.hash}) ->
              {"#{Surfex.Evidence.note()}: #{test.id}@#{test.hash} is baselined " <>
                 "(adoption: #{inspect(status.adoption)}) and #{passes}", :baseline}

            true ->
              nil
          end
      end
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
      for %{type: ^type, state: :current, relation: {_, a, b}} = r <- status.relations,
          type != :verifies or Status.validated?(status, r),
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
        case green_against(
               evidence,
               status,
               Map.fetch!(status.scans, {:test, t}),
               code,
               definition
             ) do
          nil -> nil
          {note, basis} -> {"#{note}; #{t} verifies #{s}", basis}
          note -> "#{note}; #{t} verifies #{s}"
        end
      end
    end)
  end

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
            not Status.validated?(status, r),
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

          Enum.any?(inner, &Status.validated?(status, &1)) ->
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
         # Picking a side judges nothing new: the chosen tip keeps what validated it.
         meta = with_basis(meta, chosen.basis),
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
            not MapSet.member?(status.discriminated, {test.id, test.hash}),
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
    # The log admits a basis-less implements or verifies only as legacy (§12.1), so it
    # can't tell a new one from an old one. Writing one is a bug here, and must be loud.
    if op == :relate and type in [:implements, :verifies] and is_nil(meta[:basis]),
      do:
        raise(
          ArgumentError,
          "Surfex.Record would write a basis-less #{type}: every claim it records carries a basis (§12.1)"
        )

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
