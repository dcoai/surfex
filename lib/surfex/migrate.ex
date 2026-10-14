defmodule Surfex.Migrate do
  @moduledoc """
  Moving a section's `implements` relations to the claims inside it (spec §14.1): the
  migration aid. A project moves to claim grain section by section, as work touches a
  section, never wholesale.

  A section's existing relations are the aid's **input only**, while it is migrated: what
  a claim realises is decided by the claim's tests and its own text, never by the section
  (§15.1).

    * `proposals/3` — for each live section-grain `implements` of a section, the claims
      inside it that could own it, and why.
    * `report/3` — per section, what the migration buys: relations now and after, the
      dangle width of each code item now and after, and the marking a prose section needs
      first.
    * `sections/2` — the sections a reference names: one id, or every section under a
      prefix (`--within`).

  Pure: a function of the scans and the log.
  """

  alias Surfex.Log.Entry
  alias Surfex.{Scan, Status}

  # The spec units that are claims (§11.1, §15.1). A section and a table are not: a
  # relation to one is section grain.
  @claim_roles [:block, :test_hint, :row, :rule, :contract]
  @live [:current, :dangling, :proposed]

  @typedoc "Why a claim could own a code item: a verifying test's call, a reach, or its key."
  @type reason ::
          {:calls, test :: String.t()}
          | {:reaches, through :: String.t(), test :: String.t()}
          | {:names, String.t()}

  @typedoc """
  One proposal: the code items of one definition related to `unit` (the section, or a
  table in it), and the claims inside that unit that could own them. `outcome` is `:single`
  (one claim), `:several` (listed, never decided) or `:none` (the spec work the migration
  surfaces).
  """
  @type proposal :: %{
          section: String.t(),
          unit: String.t(),
          codes: [String.t()],
          outcome: :single | :several | :none,
          claims: [%{claim: String.t(), why: [reason]}]
        }

  @doc """
  The sections `ref` names: the section with that id, or with `within: true` every section
  whose id starts with `ref` (a file, `spec/08-reclamation.md`; a prefix of ids,
  `spec.md#ctr-`), sorted. A ref naming no section is an error.
  """
  @spec sections([Scan.t()], String.t(), keyword) :: {:ok, [String.t()]} | {:error, String.t()}
  def sections(scans, ref, opts \\ []) do
    ids =
      for %Scan{kind: :spec, role: :section, id: id} <- scans,
          if(opts[:within], do: String.starts_with?(id, ref), else: id == ref),
          do: id

    case {Enum.sort(ids), opts[:within] == true} do
      {[], true} -> {:error, "no section's id starts with #{ref}"}
      {[], false} -> {:error, "#{ref} is no section"}
      {ids, _} -> {:ok, ids}
    end
  end

  @doc """
  The proposals for `sections` (§14.1): each live (current, dangling or proposed)
  `implements` between code and a section, or a table in it, grouped by definition (a
  function's default-argument arities are one proposal), paired with the claims inside
  that unit that could own it:

    * a claim **names** it: a row whose key is the code's id, or its name with no arity
      (`Mod.fun` names every arity, `Mod.fun/*`); a contract unit whose function it is;
    * a claim's verifying test (a live `verifies` to the claim or a unit inside it, or a
      declaration resolving there) **calls** it directly;
    * failing both, a claim's verifying test **reaches** it (`Surfex.Scan.reacher/1`),
      through the item the test calls.

  A claim found by a call or a name outranks one found by reach alone: a test reaching a
  helper through a public entry point is a weaker sign than one calling it. Sorted with
  `:none` first, then `:several`, then `:single`, each by section and code.
  """
  @spec proposals([Scan.t()], [Entry.t()], [String.t()]) :: [proposal]
  def proposals(scans, entries, sections),
    do: proposals_from(index(scans, Status.derive(scans, entries)), sections)

  defp proposals_from(ix, sections) do
    for section <- sections,
        unit <- [section | Map.get(ix.tables, section, [])],
        signs = signs(ix, unit),
        codes <- groups(ix, unit) do
      claims = candidates(ix, signs, codes)

      outcome =
        case claims do
          [] -> :none
          [_] -> :single
          _ -> :several
        end

      %{section: section, unit: unit, codes: codes, outcome: outcome, claims: claims}
    end
    |> Enum.sort_by(&{outcome_order(&1.outcome), &1.section, &1.codes})
  end

  defp outcome_order(:none), do: 0
  defp outcome_order(:several), do: 1
  defp outcome_order(:single), do: 2

  @typedoc "What migrating one section buys (§14.1)."
  @type section_report :: %{
          section: String.t(),
          kind: :units | :prose,
          relations: non_neg_integer,
          after: non_neg_integer,
          marking: non_neg_integer,
          implements: non_neg_integer,
          single: non_neg_integer,
          several: non_neg_integer,
          none: non_neg_integer,
          widths: [
            %{
              codes: [String.t()],
              outcome: :single | :several | :none,
              now: non_neg_integer,
              after: non_neg_integer
            }
          ]
        }

  @doc """
  What migrating each of `sections` buys, or with `:all` every section holding a
  section-grain `implements` (§14.1). Per section:

    * `relations` — the live relations on the section, of every type: what one edit of
      its text dangles now. `after`: those left once each code item with a candidate
      claim has moved.
    * `marking` — for a **prose** section (no claim inside it is a unit yet), the
      relations one marker or id comment dangles, paid once before anything can move:
      all of `relations`. `0` for a section whose claims are already **units**.
    * `implements` — its section-grain `implements`, and how many have one candidate
      (`single`), several, or none.
    * `widths` — per proposal (`proposals/3`), the relations a change to the text stating
      its claim dangles: `now`, the unit's live relations; `after`, the claim's own plus
      the moved ones (the widest candidate's, for several), or the section's `after` for
      a code item with no candidate. Widest after first.

  Sorted worst first: by `relations`, then id.
  """
  @spec report([Scan.t()], [Entry.t()], [String.t()] | :all) :: %{
          sections: [section_report],
          population: %{
            units: %{sections: non_neg_integer, implements: non_neg_integer},
            prose: %{sections: non_neg_integer, implements: non_neg_integer}
          }
        }
  def report(scans, entries, sections) do
    ix = index(scans, Status.derive(scans, entries))

    sections =
      case sections do
        :all ->
          for section <- ix.sections,
              Enum.any?([section | Map.get(ix.tables, section, [])], &(groups(ix, &1) != [])),
              do: section

        list ->
          list
      end

    reports =
      sections
      |> Enum.map(&section_report(ix, &1))
      |> Enum.sort_by(&{-&1.relations, &1.section})

    population =
      for kind <- [:units, :prose], into: %{} do
        of = Enum.filter(reports, &(&1.kind == kind))
        {kind, %{sections: length(of), implements: Enum.sum_by(of, & &1.implements)}}
      end

    %{sections: reports, population: population}
  end

  defp section_report(ix, section) do
    proposals = proposals_from(ix, [section])
    now = width(ix, section)
    count = fn outcomes -> proposals |> Enum.filter(&(&1.outcome in outcomes)) |> codes() end
    on_section = Enum.filter(proposals, &(&1.unit == section))
    moving = on_section |> Enum.filter(&(&1.outcome != :none)) |> codes()
    after_ = now - moving
    kind = if Map.get(ix.claims_in, section, []) == [], do: :prose, else: :units

    widths =
      for p <- proposals do
        after_width =
          case p.claims do
            [] ->
              if p.unit == section, do: after_, else: width(ix, p.unit)

            claims ->
              Enum.max(for c <- claims, do: width(ix, c.claim) + length(p.codes))
          end

        %{codes: p.codes, outcome: p.outcome, now: width(ix, p.unit), after: after_width}
      end
      |> Enum.sort_by(&{-&1.after, &1.codes})

    %{
      section: section,
      kind: kind,
      relations: now,
      after: after_,
      marking: if(kind == :prose, do: now, else: 0),
      implements: codes(proposals),
      single: count.([:single]),
      several: count.([:several]),
      none: count.([:none]),
      widths: widths
    }
  end

  defp codes(proposals), do: Enum.sum_by(proposals, &length(&1.codes))

  # The live relations on a spec unit: what a change to its text dangles.
  defp width(ix, unit), do: Map.get(ix.width, unit, 0)

  # ── Indexes, built once ─────────────────────────────────────────────────

  defp index(scans, status) do
    spec = for %Scan{kind: :spec} = s <- scans, into: %{}, do: {s.id, s}
    code = for %Scan{kind: :code} = s <- scans, into: %{}, do: {s.id, s}
    within = for {id, %Scan{within: w}} <- spec, w != nil, into: %{}, do: {id, w}

    live = for %{state: state} = r <- status.relations, state in @live, do: r

    width =
      for %{relation: {_, a, b}} <- live,
          {:spec, unit} <- Enum.uniq([a, b]),
          reduce: %{} do
        acc -> Map.update(acc, unit, 1, &(&1 + 1))
      end

    # Section-grain implements: code related to a section or a table, by unit.
    implemented =
      for %{type: :implements, relation: {_, {:code, c}, {:spec, u}}} <- live,
          %Scan{role: role} <- [spec[u]],
          role in [:section, :table],
          Map.has_key?(code, c),
          reduce: %{} do
        acc -> Map.update(acc, u, [c], &[c | &1])
      end

    # The claims inside each unit, and the tables of each section.
    {claims_in, tables} =
      Enum.reduce(spec, {%{}, %{}}, fn {id, s}, {claims_in, tables} ->
        claims_in =
          if s.role in @claim_roles,
            do:
              id
              |> enclosing(within)
              |> tl()
              |> Enum.reduce(claims_in, &Map.update(&2, &1, [id], fn l -> [id | l] end)),
            else: claims_in

        tables =
          if s.role == :table and s.within != nil,
            do: Map.update(tables, s.within, [id], &[id | &1]),
            else: tables

        {claims_in, tables}
      end)

    resolver = Scan.resolver(scans)

    verifies =
      for(
        %{type: :verifies, relation: {_, {:test, t}, {:spec, u}}} <- live,
        do: {t, u}
      ) ++
        for %Scan{kind: :test, declares: declares} = t <- scans,
            {:verifies, ref} <- declares,
            {:ok, unit} <- [Scan.resolve(resolver, ref)],
            do: {t.id, unit.id}

    # Each claim's verifying tests: those verifying it or a unit inside it.
    verifying =
      for {t, u} <- Enum.uniq(verifies),
          claim <- enclosing(u, within),
          spec[claim] != nil and spec[claim].role in @claim_roles,
          reduce: %{} do
        acc -> Map.update(acc, claim, MapSet.new([t]), &MapSet.put(&1, t))
      end

    tests = for %Scan{kind: :test} = t <- scans, into: %{}, do: {t.id, t}

    owner =
      for %Scan{kind: :code, role: :module} = m <- scans,
          key <- Map.keys(m.hidden),
          into: %{},
          do: {key, m.id}

    %{
      spec: spec,
      code: code,
      sections: Enum.sort(for {id, %Scan{role: :section}} <- spec, do: id),
      implemented: implemented,
      claims_in: Map.new(claims_in, fn {u, l} -> {u, Enum.sort(l)} end),
      tables: Map.new(tables, fn {s, l} -> {s, Enum.sort(l)} end),
      verifying: verifying,
      tests: tests,
      owner: owner,
      reach: Scan.reacher(scans),
      width: width
    }
  end

  # A unit's section-grain code, one group per definition, each sorted.
  defp groups(ix, unit) do
    ix.implemented
    |> Map.get(unit, [])
    |> Enum.uniq()
    |> Enum.group_by(&Scan.definition(ix.code[&1]))
    |> Map.values()
    |> Enum.map(&Enum.sort/1)
    |> Enum.sort()
  end

  # What each claim inside `unit` gives to judge a code item by, computed once per unit:
  # its key, and per verifying test the definitions it calls and those each call reaches.
  # A call to a hidden definition (a LiveView's `mount/3`) is a call to its module.
  defp signs(ix, unit) do
    definition = fn id ->
      case ix.code[id] || ix.code[ix.owner[id]] do
        nil -> nil
        scan -> Scan.definition(scan)
      end
    end

    {claims, reached} =
      Enum.map_reduce(Map.get(ix.claims_in, unit, []), %{}, fn claim, reached ->
        tests = ix.verifying |> Map.get(claim, MapSet.new()) |> Enum.sort()

        {tests, reached} =
          Enum.map_reduce(tests, reached, fn t, reached ->
            calls = Map.get(ix.tests, t, %{calls: []}).calls

            reached =
              Enum.reduce(calls, reached, fn id, acc ->
                Map.put_new_lazy(acc, id, fn ->
                  MapSet.new(ix.reach.([id]), &Scan.definition(ix.code[&1]))
                end)
              end)

            {%{test: t, calls: for(id <- calls, do: {id, definition.(id)})}, reached}
          end)

        {%{claim: claim, scan: ix.spec[claim], tests: tests}, reached}
      end)

    %{claims: claims, reached: reached, key: &key(ix, &1)}
  end

  # The claims that could own the code of one definition, with why. A claim found by a name
  # or a call outranks one found only by reach (§14.1).
  defp candidates(ix, signs, codes) do
    definition = Scan.definition(ix.code[hd(codes)])

    found =
      for %{claim: claim, scan: scan, tests: tests} <- signs.claims do
        names =
          for id <- codes, names?(scan, id), uniq: true, do: {:names, signs.key.(claim)}

        calls =
          for %{test: t, calls: calls} <- tests,
              Enum.any?(calls, &(elem(&1, 1) == definition)),
              do: {:calls, t}

        reaches =
          for %{test: t, calls: calls} <- tests,
              {id, d} <- calls,
              d != definition,
              MapSet.member?(Map.get(signs.reached, id, MapSet.new()), definition),
              uniq: true,
              do: {:reaches, id, t}

        %{claim: claim, direct: names ++ calls, reaches: reaches}
      end

    direct = for %{direct: [_ | _]} = f <- found, do: %{claim: f.claim, why: f.direct}

    if direct != [],
      do: direct,
      else: for(%{reaches: [_ | _]} = f <- found, do: %{claim: f.claim, why: f.reaches})
  end

  # A row's key names the code: its id exactly, or its name with no arity, which names
  # every arity (`Mod.fun` is `Mod.fun/*`). A contract unit names its function.
  defp names?(%Scan{role: :row, within: table, id: id}, code) do
    key = String.replace_prefix(id, table <> "/", "")
    key == code or key == String.replace(code, ~r{/\d+$}, "")
  end

  defp names?(%Scan{role: :contract, contract: contract}, code), do: contract == code
  defp names?(_claim, _code), do: false

  defp key(ix, claim) do
    case ix.spec[claim] do
      %Scan{role: :row, within: table, id: id} -> String.replace_prefix(id, table <> "/", "")
      %Scan{contract: contract} when contract != nil -> contract
      _ -> claim
    end
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
end
