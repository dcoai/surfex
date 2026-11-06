defmodule Surfex.Suggest do
  @moduledoc """
  Candidate relations from what the spec already says: every place a spec section names a
  code item is a candidate `implements` relation between the two.

  It reads the spec's citations with `Surfex.Cite`, under the project's profile
  (`Surfex.Status.Config.profile!/2`). For each **resolved** citation, the candidate is the pair *(the innermost spec
  unit containing the citation's line, each code item the citation names)*: a citation in
  a marked block relates the block, not its section. A family (`Mod.fun`) names every
  member. Leaving things out:

    * a pair already related, in any state, including retired: suggesting it again would
      overrule a decision already on record
    * a citation inside a fenced code block, which has no line to place it in a section
    * a named item that is not a code scan (a file target, say)
    * in an **established** log (`established?/1`), a prose citation outside a contract
      unit: once something is related on a validated basis, code relates to the claim
      it realises, not to the sentence that names it (§15.4)

  This is also how a project adopts the relation log: `mix surfex.log --init`, then
  `mix surfex.suggest --accept`.
  """

  alias Surfex.{Cite, Profile, Record, Scan}
  alias Surfex.Log.Entry

  @typedoc """
  A candidate `implements` relation: from a citation (`cited_at` its file and line), or
  from what a claim's verifying tests call (`cited_at` nil, `tests` the tests that call
  it, `shared` how many other claims' verifying tests call it too, §15.1).
  """
  @type candidate :: %{
          required(:spec) => Scan.t(),
          required(:code) => Scan.t(),
          required(:cited_at) => {String.t(), pos_integer} | nil,
          optional(:tests) => [String.t()],
          optional(:shared) => non_neg_integer
        }

  # The bases that record a validation (§18): a proposal records none.
  @validating [:evidence, :review, :judgement, :baseline]

  @doc """
  The candidates, sorted by section then item, one per pair: the first citation that
  proposes a pair is where it was cited. In an established log (`established?/1`), a
  prose citation (`kind: :span`) proposes only inside a contract unit; subject headings,
  contract keys and citing cells still do (§15.4).
  """
  @spec candidates(Profile.t(), [Surfex.Item.t()], [Scan.t()], [Entry.t()], String.t()) :: [
          candidate
        ]
  def candidates(profile, items, scans, entries, root),
    do: profile |> cited(items, scans, entries, root) |> elem(0)

  @doc """
  Whether the log is **established** (§15.4): it holds a live `implements` whose judgement
  in force records a validation (evidence, a review, a judgement or a baseline). Derived
  from the log alone: the first such relation ends the citation bootstrap, and retiring
  the last one brings it back.
  """
  @spec established?([Entry.t()]) :: boolean
  def established?(entries) do
    entries
    |> Enum.filter(&(&1.type == :implements))
    |> live_tips()
    |> Enum.any?(&(&1.op == :relate and &1.basis in @validating))
  end

  # Candidates, and the pairs a prose citation would have proposed but for the
  # established log (§15.4), each with the citation's span.
  defp cited(profile, items, scans, entries, root) do
    citations = Cite.citations(items, profile, root)
    sections = Enum.filter(scans, &(&1.kind == :spec))
    code = for s <- scans, s.kind == :code, into: %{}, do: {s.id, s}
    related = MapSet.new(entries, &Entry.relation/1)
    established = established?(entries)

    pairs =
      for %{status: :resolved} = c <- citations,
          c.section != "(code block)",
          section = section_at(sections, c.file, c.line),
          section != nil,
          key <- c.items,
          item = Map.get(code, key),
          item != nil,
          not MapSet.member?(related, Entry.relation(:implements, section, item)) do
        {proposes?(c, section, established),
         %{spec: section, code: item, cited_at: {c.file, c.line}}, c.span}
      end

    {proposed, withheld} = Enum.split_with(pairs, &elem(&1, 0))

    {proposed
     |> Enum.map(&elem(&1, 1))
     |> Enum.uniq_by(&{&1.spec.id, &1.code.id})
     |> Enum.sort_by(&{&1.spec.id, &1.code.id}),
     Enum.map(withheld, fn {false, c, span} -> Map.put(c, :span, span) end)}
  end

  # A subject or a cell names what its unit is about; a span is narration unless its unit
  # is a contract, whose text states the code (§15.4).
  defp proposes?(_citation, _unit, false), do: true
  defp proposes?(%{kind: kind}, _unit, true) when kind in [:subject, :cell], do: true
  defp proposes?(%{kind: :span}, %Scan{role: role}, true), do: role == :contract

  @doc """
  The command that declines a judgement suggestion (§14, §15): a `retire` of the
  never-related pair, with a note the reviewer replaces, so the decision is recorded and
  never proposed again. `implements` and `excuses` are judgements; a structural suggestion
  (`tests`, `refines`, a refresh) states what the source says, and has none (`nil`).
  """
  @spec decline_command(atom, String.t(), String.t()) :: String.t() | nil
  def decline_command(:implements, spec, code),
    do: retire_command(:implements, "spec:" <> spec, "code:" <> code)

  def decline_command(:excuses, class, code),
    do: retire_command(:excuses, "class:" <> class, "code:" <> code)

  def decline_command(_structural, _from, _to), do: nil

  @doc """
  The command that records a claim-derived candidate after review (§15.5): a `relate` of
  the pair as `implements`, ids kind-prefixed and quoted, with a note the reviewer
  replaces.
  """
  @spec relate_command(String.t(), String.t()) :: String.t()
  def relate_command(spec, code),
    do:
      "mix surfex.relate #{quoted("spec:" <> spec)} #{quoted("code:" <> code)} " <>
        ~s(--type implements --note "what the claim's tests show it realises")

  @doc """
  Whether a candidate comes from a claim's tests (§15.1) rather than a citation or a
  contract's own function: a judgement reviewed pair by pair, which `accept_all/5` never
  records (§15.5).
  """
  @spec claim_derived?(candidate) :: boolean
  def claim_derived?(%{cited_at: cited_at}), do: cited_at == nil

  defp retire_command(type, from, to),
    do:
      ~s(mix surfex.retire #{quoted(from)} #{quoted(to)} --type #{type} --note "why it isn't one")

  defp quoted(id), do: ~s(") <> String.replace(id, ~s("), ~s(\\")) <> ~s(")

  @doc """
  One `relate` entry per candidate, at the current hashes. It only ever creates relations
  that don't exist; it never confirms a dangling one.
  """
  @spec accept([candidate], [Scan.t()], [Entry.t()], keyword) ::
          {:ok, [Entry.t()]} | {:error, String.t()}
  def accept(candidates, scans, entries, meta) do
    Enum.reduce_while(candidates, {:ok, []}, fn c, {:ok, acc} ->
      case Record.relate(
             scans,
             entries ++ acc,
             "spec:" <> c.spec.id,
             "code:" <> c.code.id,
             :implements,
             meta
           ) do
        {:ok, recorded} -> {:cont, {:ok, acc ++ recorded}}
        error -> {:halt, error}
      end
    end)
  end

  @type move :: %{from: String.t(), to: Scan.t()}
  @type ambiguous :: %{from: [String.t()], to: [String.t()]}
  @type refinement :: %{from: Scan.t(), to: Scan.t()}
  @type pair :: %{from: Scan.t(), to: Scan.t()}
  @type suggestions :: %{
          moves: [move],
          ambiguous: [ambiguous],
          refines: [refinement],
          implements: [candidate],
          verifies: [pair],
          tests: [pair],
          excuses: [pair],
          reached: [%{spec: String.t(), through: String.t(), count: pos_integer}],
          also_called: [%{spec: String.t(), count: pos_integer}],
          withheld: [%{spec: String.t(), span: String.t(), cited_at: {String.t(), pos_integer}}],
          undeclared: [%{test: String.t(), spec: String.t(), validated: boolean}],
          moved: [%{from: String.t(), to: String.t(), now: String.t()}],
          migrated: [%{code: String.t(), section: String.t(), claims: [String.t()]}],
          refresh: [%{type: atom, from: Scan.t(), to: Scan.t()}]
        }

  @doc """
  Every suggestion at once, computed together so none repeats another:

    * **moves** — a spec or test id the log knows that is no longer scanned, and a new id
      of the same kind with no records of its own at the **same version**: a renamed
      heading or an added anchor; a test whose module, `describe` or file was renamed (a
      split test file). Only a one-to-one match is suggested.
    * **ambiguous** — versions found under more than one gone id or new id: reported, not
      suggested, since which is which is a judgement.
    * **refines** — each marked block and test hint `refines` the section or block it sits
      in (`within`), unless that relation exists in any state.
    * **implements** — `candidates/5`.
    * **verifies** — each test's declaration (`@tag verifies: "id"`) that resolves to a
      spec unit (`Surfex.Scan.resolve/2`).
    * **tests** — each test paired with each scanned code item it calls (in its body or
      the private helpers it reaches).
    * **refresh** — each dangling structural relation (`tests`, `refines`) whose fact the
      source still states: the test still calls or names the code, the unit still holds
      the block or hint. Judgement relations (`implements`, `verifies`, `excuses`) are never
      refreshed.
    * **undeclared** — each `verifies` relation whose test no longer declares it
      (`Surfex.Status`), to retire: the test's source no longer makes the claim. One resting
      on a judgement is marked `validated`, and retired only when asked (`accept_all/5`).
    * **moved** — each `refines` relation whose unit no longer sits in what it refines
      (`Surfex.Status`), to retire: the source no longer states it. The unit's new place
      is suggested under refines, so accepting settles both.
    * **migrated** — each code item a migration (§14.1) moved from a section to claims
      whose relations are all validated now: the section's relation, to retire, noting the
      claims (`Surfex.Migrate.settled_note/2`).
    * **excuses** — each code item nothing implements (and no implements candidate will),
      paired with the class of the first rule it matches, as `Surfex.Coverage` matches
      them. A parent counts as cited when something implements it. `never_excused`
      kinds are never excused.

  Refines and implements are computed as if the moves were already recorded, so a moved
  section's relations aren't suggested again under its new id.

  **implements** also pairs each claim (a block, test hint, row, rule or contract) with
  the scanned code its verifying tests call directly (§15.1), only when neither the claim
  nor a unit it sits in has a live `implements` or one proposed in this run, and only the
  calls with the claim's lowest `shared`: how many other claims' tests make the same call.
  **also_called** counts, per claim, the calls left out that way: `%{spec, count}`.
  **reached** lists, per such claim, each code item those tests call that reaches more
  code: `%{spec, through, count}`. Both are information for a person to act on with
  `relate`, never recorded. A claim-derived candidate (`claim_derived?/1`) is a judgement
  reviewed pair by pair: `accept_all/5` never records it (§15.5).

  **withheld** lists, in an established log, each prose citation that proposed nothing
  because of it (§15.4): `%{spec, span, cited_at}`, one per citation whose pair no other
  source proposes. It is information, never recorded and not counted as a suggestion.

  A citation in a classed section's own text (§15.2) proposes no `implements`, and a
  declaration naming a classed unit proposes no `verifies`: the class says that text
  asserts nothing (§13.6).
  """
  # Only for computing what the moves would leave; never recorded.
  @epoch "1970-01-01T00:00:00Z"

  @spec all(Profile.t(), [Surfex.Item.t()], [Scan.t()], [Entry.t()], String.t()) ::
          suggestions
  def all(profile, items, scans, entries, root) do
    {moves, ambiguous} = moves(scans, entries)
    {moves, ambiguous} = {ordered(moves), ordered(ambiguous)}

    {:ok, moved} =
      Enum.reduce(moves, {:ok, entries}, fn m, {:ok, acc} ->
        {:ok, recorded} =
          Record.move(scans, acc, prefixed(m.to.kind, m.from), prefixed(m.to), at: @epoch)

        {:ok, acc ++ recorded}
      end)

    # A contract's key names its function (§15.3): those pairs come first, whatever else
    # proposes them.
    own = own_functions(scans, moved)
    owned = MapSet.new(own, &{&1.spec.id, &1.code.id})

    # The class says a classed unit's own text asserts nothing (§15.2).
    {cited, held} = cited(profile, items, scans, moved, root)
    cited = Enum.reject(cited, &(&1.spec.class != nil or MapSet.member?(owned, pair(&1))))

    # A claim's tests are always a source (§15.1): once the log is established they are
    # the route left for code a prose citation names (§15.4).
    {claimed, reached, also_called} = claims(scans, moved, own ++ cited)

    implements = own ++ cited ++ claimed
    status = Surfex.Status.derive(scans, moved)

    %{
      moves: moves,
      ambiguous: ambiguous,
      refines: ordered(refinements(scans, moved)),
      implements: ordered(own) ++ ordered(cited ++ claimed),
      excuses: ordered(excusals(profile, items, scans, moved, implements)),
      reached: ordered(reached),
      also_called: ordered(also_called),
      withheld: withheld(held, implements),
      verifies: ordered(Enum.reject(verifications(scans, moved), &(&1.to.class != nil))),
      undeclared: ordered(undeclared(status)),
      moved: ordered(status.moved),
      migrated:
        ordered(
          for(
            %{settled: true} = m <- status.migrating,
            do: %{code: m.code, section: m.section, claims: m.claims}
          )
        ),
      refresh: ordered(refreshed(scans, status)),
      tests: ordered(exercised(scans, moved))
    }
  end

  defp pair(candidate), do: {candidate.spec.id, candidate.code.id}

  # The prose citations an established log didn't turn into candidates (§15.4), one per
  # citation: those with a pair no other source proposes, outside a classed unit (whose
  # own text proposes nothing anyway, §15.2).
  defp withheld(held, implements) do
    proposed = MapSet.new(implements, &pair/1)

    held
    |> Enum.reject(&(&1.spec.class != nil or MapSet.member?(proposed, pair(&1))))
    |> Enum.uniq_by(&{&1.cited_at, &1.span})
    |> Enum.map(&%{spec: &1.spec.id, span: &1.span, cited_at: &1.cited_at})
    |> Enum.sort_by(&{&1.cited_at, &1.span})
  end

  # §15.3: each contract unit and the code item of its own key, a `@spec`'s
  # `Module.name/arity` and a callback's `Module.callback:name/arity`, unless a relation
  # relates them in any state. Cited at the contract's line: the key is the claim.
  defp own_functions(scans, entries) do
    code = for %Scan{kind: :code} = s <- scans, into: %{}, do: {s.id, s}
    related = MapSet.new(entries, &Entry.relation/1)

    for %Scan{kind: :spec, role: :contract} = unit <- scans,
        item = Map.get(code, own_key(unit)),
        item != nil,
        not MapSet.member?(related, Entry.relation(:implements, unit, item)) do
      %{spec: unit, code: item, cited_at: {unit.location.file, elem(unit.location.lines, 0)}}
    end
  end

  defp own_key(%Scan{id: id, contract: contract}) do
    [_file, key] = String.split(id, "#", parts: 2)
    if Regex.match?(~r/\.(macro)?callback:/, key), do: key, else: contract
  end

  # A verifier as status lists it (`check ID` for a check, §11.4), as an id to record by.
  defp retiring(undeclared, opts) do
    if opts[:retire_undeclared], do: undeclared, else: Enum.reject(undeclared, & &1.validated)
  end

  # Each undeclared relation, and whether its tip rests on a judgement a retire would lose.
  defp undeclared(status) do
    validated =
      for %{type: :verifies, tip: %{basis: basis}, relation: {_, from, {:spec, unit}}} <-
            status.relations,
          basis in @validating,
          into: MapSet.new(),
          do: {verifier_label(from), unit}

    for u <- status.undeclared,
        do: Map.put(u, :validated, MapSet.member?(validated, {u.test, u.spec}))
  end

  defp verifier_label({:check, check}), do: "check " <> check
  defp verifier_label({:test, test}), do: test

  defp verifier_ref("check " <> check), do: "check:" <> check
  defp verifier_ref(test), do: "test:" <> test

  # Suggestions in one canonical order, by the ids they name, so they never follow the
  # order the scans or the log's lines came in (#151): a union merge reorders lines, and a
  # file system lists files as it likes.
  defp ordered(suggestions), do: Enum.sort_by(suggestions, &order_key/1)

  defp order_key(suggestion) do
    id = fn
      %Scan{id: id} -> id
      list when is_list(list) -> Enum.map(list, &if(is_struct(&1, Scan), do: &1.id, else: &1))
      other -> other
    end

    for key <- [:from, :to, :spec, :code, :test, :type], do: id.(Map.get(suggestion, key))
  end

  @doc """
  Records suggestions: each move (`Surfex.Record.move/5`), then each other suggestion as
  a `relate` at the current hashes, and each proposed undeclared `verifies` relation and
  each moved `refines` relation as a `retire`. An undeclared relation resting on a
  judgement is retired only with `retire_undeclared: true`: a tag can go by mistake (§15). `implements`, `verifies` and `excuses` relations are recorded as proposed,
  a `verifies` relation on its failing run when `opts[:evidence]` shows one (§18).
  Moves carry each relation's basis across. It re-records a dangling relation only
  when it is structural and the source still states it (refresh); it never confirms a
  dangling judgement.
  """
  @spec accept_all(suggestions, [Scan.t()], [Entry.t()], keyword, keyword) ::
          {:ok, [Entry.t()]} | {:error, String.t()}
  def accept_all(suggestions, scans, entries, meta, opts \\ []) do
    steps =
      Enum.map(suggestions.moves, fn m ->
        &Record.move(scans, &1, prefixed(m.to.kind, m.from), prefixed(m.to), meta)
      end) ++
        Enum.map(suggestions.refines, fn r ->
          &Record.relate(scans, &1, "spec:" <> r.from.id, "spec:" <> r.to.id, :refines, meta)
        end) ++
        Enum.map(suggestions.verifies, fn v ->
          &Record.relate(
            scans,
            &1,
            "#{v.from.kind}:#{v.from.id}",
            "spec:" <> v.to.id,
            :verifies,
            meta,
            opts
          )
        end) ++
        Enum.map(suggestions.tests, fn t ->
          &Record.relate(scans, &1, "test:" <> t.from.id, "code:" <> t.to.id, :tests, meta)
        end) ++
        Enum.map(suggestions.refresh, fn f ->
          &Record.relate(
            scans,
            &1,
            "#{f.from.kind}:#{f.from.id}",
            "#{f.to.kind}:#{f.to.id}",
            f.type,
            Keyword.put_new(meta, :note, "the source still states it")
          )
        end) ++
        Enum.map(retiring(suggestions.undeclared, opts), fn u ->
          &Record.retire(
            scans,
            &1,
            verifier_ref(u.test),
            "spec:" <> u.spec,
            :verifies,
            Keyword.put_new(meta, :note, "the test no longer declares that it verifies this")
          )
        end) ++
        Enum.map(suggestions.moved, fn m ->
          &Record.retire(
            scans,
            &1,
            "spec:" <> m.from,
            "spec:" <> m.to,
            :refines,
            Keyword.put_new(meta, :note, "the unit no longer sits in it")
          )
        end) ++
        Enum.map(suggestions.migrated, fn m ->
          &Record.retire(
            scans,
            &1,
            "code:" <> m.code,
            "spec:" <> m.section,
            :implements,
            Surfex.Migrate.settled_note(m.claims, meta)
          )
        end) ++
        Enum.map(suggestions.excuses, fn x ->
          &Record.relate(scans, &1, "class:" <> x.from.id, "code:" <> x.to.id, :excuses, meta)
        end)

    with {:ok, recorded} <-
           Enum.reduce_while(steps, {:ok, []}, fn step, {:ok, acc} ->
             case step.(entries ++ acc) do
               {:ok, more} -> {:cont, {:ok, acc ++ more}}
               error -> {:halt, error}
             end
           end),
         {:ok, implemented} <-
           suggestions.implements
           |> Enum.reject(&claim_derived?/1)
           |> accept(scans, entries ++ recorded, meta) do
      {:ok, recorded ++ implemented}
    end
  end

  @doc """
  The suggestions as JSON (§15.5), for tools and agents: each list under its key, a scan
  given by its id and a place as `"file:line"`. Each `implements` candidate carries
  `spec`, `code`, `cited_at` (`null` for a claim's tests), `tests`, `shared` (`null` for
  a citation's) and `accept`, whether `--accept` records it.
  """
  @spec json(suggestions) :: String.t()
  def json(suggestions) do
    suggestions
    |> Map.new(fn
      {:implements, list} -> {:implements, Enum.map(list, &candidate_json/1)}
      {key, list} -> {key, Enum.map(list, &plain/1)}
    end)
    |> JSON.encode!()
  end

  defp candidate_json(c),
    do: %{
      spec: c.spec.id,
      code: c.code.id,
      cited_at: plain(c.cited_at),
      tests: Map.get(c, :tests, []),
      shared: Map.get(c, :shared),
      accept: not claim_derived?(c)
    }

  defp plain(%Scan{id: id}), do: id
  defp plain({file, line}) when is_binary(file), do: "#{file}:#{line}"
  defp plain(list) when is_list(list), do: Enum.map(list, &plain/1)
  defp plain(%{} = map), do: Map.new(map, fn {k, v} -> {k, plain(v)} end)
  defp plain(other), do: other

  defp prefixed(kind, id), do: "#{kind}:#{id}"
  defp prefixed(%Scan{kind: kind, id: id}), do: prefixed(kind, id)

  # Moves of spec units and tests, and the matches too ambiguous to suggest.
  defp moves(scans, entries) do
    status = Surfex.Status.derive(scans, entries)
    scanned = MapSet.new(scans, &{&1.kind, &1.id})

    # Ends of orphaned relations, and a test's observations: a test may have records and
    # no relation (§14).
    # A retired relation's gone end counts too: its retirement is a decision to carry (§14).
    orphaned =
      for %{state: state, tip: %Entry{} = tip, changed: changed} <- status.relations,
          state in [:orphaned, :retired],
          end_ <- tip.ends,
          end_.kind in [:spec, :test],
          state == :retired or {end_.kind, end_.id} in changed,
          not MapSet.member?(scanned, {end_.kind, end_.id}),
          do: {end_.kind, end_.id, end_.hash}

    observed =
      for %Entry{op: :observe, ends: [%{kind: kind, id: id, hash: hash}]} <- entries,
          not MapSet.member?(scanned, {kind, id}),
          not Enum.any?(orphaned, &match?({^kind, ^id, _}, &1)),
          do: {kind, id, hash}

    gone =
      Enum.reduce(orphaned ++ observed, %{}, fn {kind, id, hash}, acc ->
        Map.update(acc, {kind, id}, MapSet.new([hash]), &MapSet.put(&1, hash))
      end)

    recorded = MapSet.new(for e <- entries, end_ <- e.ends, do: {end_.kind, end_.id})

    fresh =
      for %Scan{kind: kind} = s <- status.new,
          kind in [:spec, :test],
          not MapSet.member?(recorded, {kind, s.id}),
          do: s

    gone_by_version =
      gone
      |> Enum.filter(fn {_key, hashes} -> MapSet.size(hashes) == 1 end)
      |> Enum.group_by(fn {{kind, _id}, hashes} -> {kind, Enum.at(hashes, 0)} end, fn {{_k, id},
                                                                                       _} ->
        id
      end)

    fresh_by_version = Enum.group_by(fresh, &{&1.kind, &1.hash})

    matches =
      for {version, olds} <- gone_by_version,
          news = Map.get(fresh_by_version, version, []),
          news != [],
          do: {Enum.sort(olds), Enum.sort_by(news, & &1.id)}

    matches = matches ++ code_matches(status, scans, scanned, recorded)

    {for({[old], [new]} <- matches, do: %{from: old, to: new}),
     for(
       {olds, news} <- matches,
       length(olds) > 1 or length(news) > 1,
       do: %{from: olds, to: Enum.map(news, & &1.id)}
     )}
  end

  # A function whose arity changed (#153): a code id with live or retired relations is no
  # longer scanned, and a new code item of the same module and name, with another arity,
  # has no records. Its version changed with it, so the version rule above can't see it.
  defp code_matches(status, scans, scanned, recorded) do
    name = fn id ->
      case Regex.run(~r{^(.+)/\d+$}, id) do
        [_, name] -> name
        nil -> nil
      end
    end

    gone =
      for %{state: state, tip: %Entry{} = tip} <- status.relations,
          state in [:orphaned, :retired],
          %{kind: :code, id: id} <- tip.ends,
          not MapSet.member?(scanned, {:code, id}),
          name.(id) != nil,
          uniq: true,
          do: id

    fresh =
      for %Scan{kind: :code, in_parent: false} = s <- scans,
          not MapSet.member?(recorded, {:code, s.id}),
          name.(s.id) != nil,
          do: s

    fresh_by_name = Enum.group_by(fresh, &name.(&1.id))

    for {key, olds} <- Enum.group_by(gone, name),
        news = Map.get(fresh_by_name, key, []),
        news != [],
        do: {Enum.sort(olds), Enum.sort_by(news, & &1.id)}
  end

  # Claim relations from a claim's tests (§15.1): each claim paired with the scanned code
  # its verifying tests call directly, and, per claim, each such call that reaches more
  # code, with how much. A verifying test is one with a live `verifies` relation to the
  # claim or a unit inside it, or a declaration that resolves there. A hidden definition
  # a call names (a LiveView's `mount/3`, a server's `handle_call/3`) is its module's
  # code: the module is the item. A module named by itself is not proposed: a test names
  # every module it calls into.
  #
  # The claims code can be proposed to (§14.1, §15.1): a section holding claims is what a
  # migration moves code off, so it is a claim for the verdicts and no target here.
  defp proposable_claims(scans) do
    claims = for %Scan{kind: :spec} = s <- scans, Surfex.Status.Verdict.claim?(s), do: s
    up = for %Scan{kind: :spec} = s <- scans, into: %{}, do: {s.id, s.within || s.under}

    holding =
      for %Scan{id: id} <- claims,
          outer <- tl(enclosing(id, up)),
          into: MapSet.new(),
          do: outer

    for %Scan{} = s <- claims,
        s.role != :section or not MapSet.member?(holding, s.id),
        into: %{},
        do: {s.id, s}
  end

  # Only a claim nothing implements is proposed for (#329): neither it nor a unit it sits
  # in (`within`, else `under`) has a live `implements` or one proposed in this run by a
  # citation or a contract's key. Of its candidates, only those other claims' tests call
  # least (`shared`) are proposed; the rest are counted per claim (`also_called`).
  defp claims(scans, entries, proposed) do
    code = for %Scan{kind: :code} = s <- scans, s.role != :module, into: %{}, do: {s.id, s}

    owner =
      for %Scan{kind: :code, role: :module} = m <- scans,
          key <- Map.keys(m.hidden),
          into: %{},
          do: {key, m}

    tests = for %Scan{kind: :test} = t <- scans, into: %{}, do: {t.id, t}

    claims = proposable_claims(scans)

    within = for %Scan{kind: :spec, within: w} = s <- scans, w != nil, into: %{}, do: {s.id, w}
    related = MapSet.new(entries, &Entry.relation/1)
    cited = MapSet.new(proposed, &{&1.spec.id, &1.code.id})
    resolver = Scan.resolver(scans)

    up =
      for %Scan{kind: :spec} = s <- scans,
          parent = s.within || s.under,
          parent != nil,
          into: %{},
          do: {s.id, parent}

    implemented =
      MapSet.new(
        for(
          %Entry{op: :relate, type: :implements, ends: ends} <- live_tips(entries),
          %{kind: :spec, id: id} <- ends,
          do: id
        ) ++ Enum.map(proposed, & &1.spec.id)
      )

    open? = fn claim -> not Enum.any?(enclosing(claim, up), &MapSet.member?(implemented, &1)) end

    verifies =
      for(
        %Entry{op: :relate, type: :verifies, ends: [%{id: t}, %{id: u}]} <- live_tips(entries),
        do: {t, u}
      ) ++
        for %Scan{kind: :test, declares: declares} = t <- Map.values(tests),
            {:verifies, ref} <- declares,
            {:ok, unit} <- [Scan.resolve(resolver, ref)],
            do: {t.id, unit.id}

    verifying =
      for {t, unit} <- Enum.uniq(verifies),
          Map.has_key?(tests, t),
          claim <- enclosing(unit, within),
          Map.has_key?(claims, claim),
          reduce: %{} do
        acc -> Map.update(acc, claim, MapSet.new([t]), &MapSet.put(&1, t))
      end

    target = fn id -> Map.get(code, id) || Map.get(owner, id) end
    reach = Scan.reacher(scans)

    per_claim =
      for {claim, ts} <- verifying do
        called =
          for t <- ts, id <- tests[t].calls, scan = target.(id), scan != nil, do: {id, scan, t}

        {claim, called}
      end

    # Every claim whose tests call each code item, whether or not it is proposed for.
    callers =
      for {claim, called} <- per_claim, {_id, scan, _t} <- called, reduce: %{} do
        acc -> Map.update(acc, scan.id, MapSet.new([claim]), &MapSet.put(&1, claim))
      end

    open = for {claim, called} <- per_claim, open?.(claim), do: {claim, called}

    per_open =
      for {claim, called} <- open do
        found =
          for {code_id, group} <- Enum.group_by(called, &elem(&1, 1).id),
              spec = claims[claim],
              scan = elem(hd(group), 1),
              not MapSet.member?(cited, {claim, code_id}),
              not MapSet.member?(related, Entry.relation(:implements, spec, scan)),
              do: %{
                spec: spec,
                code: scan,
                cited_at: nil,
                tests: group |> Enum.map(&elem(&1, 2)) |> Enum.uniq() |> Enum.sort(),
                shared: MapSet.size(callers[code_id]) - 1
              }

        {claim, most_specific(found)}
      end

    candidates = for {_claim, {kept, _rest}} <- per_open, c <- kept, do: c

    also_called =
      for {claim, {_kept, rest}} <- per_open, rest > 0, do: %{spec: claim, count: rest}

    # Each call's reach once, however many claims' tests make it.
    reaches =
      for {_claim, called} <- per_claim,
          {id, _scan, _t} <- called,
          uniq: true,
          into: %{},
          do: {id, reach.([id])}

    reached =
      for {claim, called} <- open,
          direct = MapSet.new(called, &elem(&1, 1).id),
          calls = called |> Enum.map(&elem(&1, 0)) |> Enum.uniq(),
          id <- calls,
          beyond =
            Enum.count(
              reaches[id],
              &(Map.has_key?(code, &1) and &1 != id and not MapSet.member?(direct, &1))
            ),
          beyond > 0,
          do: %{spec: claim, through: id, count: beyond}

    {candidates, reached, also_called}
  end

  # A claim's candidates with the lowest `shared`, and how many others there were.
  defp most_specific([]), do: {[], 0}

  defp most_specific(found) do
    least = found |> Enum.map(& &1.shared) |> Enum.min()
    {kept, rest} = Enum.split_with(found, &(&1.shared == least))
    {kept, length(rest)}
  end

  # `unit` and every unit it sits in, innermost first.
  defp enclosing(unit, within), do: enclosing(unit, within, [])

  defp enclosing(unit, within, seen) do
    if unit in seen do
      Enum.reverse(seen)
    else
      case Map.fetch(within, unit) do
        {:ok, parent} -> enclosing(parent, within, [unit | seen])
        :error -> Enum.reverse([unit | seen])
      end
    end
  end

  defp excusals(profile, items, scans, entries, implements) do
    classes = for %Scan{kind: :class} = s <- scans, into: %{}, do: {s.id, s}
    code = for %Scan{kind: :code} = s <- scans, into: %{}, do: {s.id, s}
    related = MapSet.new(entries, &Entry.relation/1)

    implemented =
      MapSet.new(
        for(
          %Entry{type: :implements, op: :relate, ends: ends} <- live_tips(entries),
          %{kind: :code, id: id} <- ends,
          do: id
        ) ++ Enum.map(implements, & &1.code.id)
      )

    for item <- items,
        scan = Scan.for_item(Map.values(code), item),
        scan != nil,
        not MapSet.member?(implemented, scan.id),
        {:expected, class} <- [Surfex.Coverage.verdict(item, implemented, profile)],
        class_scan = Map.get(classes, class),
        class_scan != nil,
        not MapSet.member?(related, Entry.relation(:excuses, class_scan, scan)),
        uniq: true,
        do: %{from: class_scan, to: scan}
  end

  # The judgement in force for each relation, when there is exactly one. Each relation's
  # tips come from its own entries: re-filtering the whole log per relation made suggest
  # quadratic in the log (#168).
  defp live_tips(entries) do
    entries
    |> Enum.group_by(&Entry.relation/1)
    |> Enum.flat_map(fn {relation, group} ->
      case Surfex.Status.representative(Surfex.Status.tips(group, relation)) do
        nil -> []
        tip -> [tip]
      end
    end)
  end

  # A dangling structural relation whose fact the source still states: the test still
  # calls or names the code (`tests`), the block or hint still sits in the unit
  # (`refines`). It records a fact read from source, not a judgement, so re-reading the
  # source is what re-establishes it (§18). Judgement relations are never refreshed.
  defp refreshed(scans, status) do
    by_id = Map.new(scans, &{{&1.kind, &1.id}, &1})

    for %{state: :dangling, type: type, relation: {_, a, b}} <- status.relations,
        type in [:tests, :refines],
        from = by_id[a],
        to = by_id[b],
        still?(type, from, to),
        do: %{type: type, from: from, to: to}
  end

  defp still?(:tests, %Scan{calls: calls}, %Scan{id: id}), do: id in calls
  defp still?(:refines, %Scan{within: within}, %Scan{id: id}), do: within == id

  defp verifications(scans, entries) do
    related = MapSet.new(entries, &Entry.relation/1)
    resolver = Scan.resolver(scans)

    # A check declares what it verifies as a test does (§11.4).
    for %Scan{kind: kind, declares: declares} = test <- scans,
        kind in [:test, :check],
        {:verifies, ref} <- declares,
        {:ok, spec} <- [Scan.resolve(resolver, ref)],
        not MapSet.member?(related, Entry.relation(:verifies, test, spec)),
        uniq: true,
        do: %{from: test, to: spec}
  end

  defp exercised(scans, entries) do
    code = for %Scan{kind: :code} = s <- scans, into: %{}, do: {s.id, s}
    related = MapSet.new(entries, &Entry.relation/1)

    for %Scan{kind: :test, calls: calls} = test <- scans,
        id <- calls,
        item = Map.get(code, id),
        item != nil,
        not MapSet.member?(related, Entry.relation(:tests, test, item)),
        do: %{from: test, to: item}
  end

  defp refinements(scans, entries) do
    by_id = for %Scan{kind: :spec} = s <- scans, into: %{}, do: {s.id, s}
    related = MapSet.new(entries, &Entry.relation/1)

    for %Scan{kind: :spec, within: within} = unit <- scans,
        within != nil,
        parent = Map.fetch!(by_id, within),
        not MapSet.member?(related, Entry.relation(:refines, unit, parent)),
        do: %{from: unit, to: parent}
  end

  # The innermost spec unit holding the citation: a citation in a marked block is about
  # the block's requirement (`Surfex.Scan.at/3`).
  defp section_at(sections, file, line), do: Scan.at(sections, file, line)
end
