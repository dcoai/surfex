defmodule Surfex.SuggestTest do
  use ExUnit.Case, async: true
  @moduletag verifies: "suggest-proposes"

  alias Surfex.{Item, Scan, Status, Suggest}
  alias Surfex.Status.Config
  alias Surfex.Scan.Markdown
  alias Surfex.Log.Entry

  @fixture Path.expand("../fixtures/reference", __DIR__)
  @root Path.join(@fixture, "sources")
  @meta [by: "tester", at: "2026-09-28T10:00:00Z"]

  setup_all do
    {items, _} = Code.eval_file(Path.join(@fixture, "items.exs"))
    items = Enum.map(items, &struct!(Item, &1))
    {config, _} = Code.eval_file(Path.join(@fixture, "surfex.exs"))
    profile = Config.profile!(config, nil)
    scans = Markdown.records(@root, ["spec/**/*.md", "notes/**/*.md"]) ++ Scan.code(items)
    %{profile: profile, items: items, scans: scans}
  end

  defp candidates(c, entries \\ []),
    do: Suggest.candidates(c.profile, c.items, c.scans, entries, @root)

  defp pairs(candidates), do: Enum.map(candidates, &{&1.spec.id, &1.code.id})

  @wire "spec/02-wire.md#02 — Wire format"
  @overview "spec/01-overview.md#01 — Overview/1. Sending and receiving"

  test "a citation pairs its section with the item it names", c do
    pairs = pairs(candidates(c))
    assert {"#{@wire}/2. Packet types", "PING"} in pairs
    assert {@overview, "wren_recv"} in pairs
  end

  test "a subject heading, a table cell and a member path each propose their items", c do
    pairs = pairs(candidates(c))
    assert {"#{@wire}/3. PING — 24 bytes", "wren_ping_hdr"} in pairs
    assert {"#{@wire}/1. Common header — 8 bytes", "wren_hdr.len"} in pairs
    assert {"#{@wire}/3. PING — 24 bytes", "wren_ping_hdr.ack"} in pairs
    assert {"#{@wire}/3. PING — 24 bytes", "wren_ack.id"} in pairs
  end

  test "code-block citations, file targets and unresolved names propose nothing", c do
    candidates = candidates(c)
    refute Enum.any?(candidates, &(&1.code.id == "wren.h"))
    refute Enum.any?(candidates, &(&1.code.id in ["wren_send_all", "wren_twin", "wren_retry"]))
    # wren_send is cited both in prose and in a code block; only the prose citation counts.
    assert [%{cited_at: {"spec/01-overview.md", 7}}] =
             Enum.filter(candidates, &(&1.code.id == "wren_send"))
  end

  test "each candidate records where it was cited, once per pair", c do
    candidates = candidates(c)
    assert length(candidates) == length(Enum.uniq(pairs(candidates)))

    assert Enum.all?(
             candidates,
             &match?(%{cited_at: {"spec/" <> _, line}} when is_integer(line), &1)
           )
  end

  test "accept records one relation each, and a second run suggests nothing", c do
    first = candidates(c)
    {:ok, entries} = Suggest.accept(first, c.scans, [], @meta)
    assert length(entries) == length(first)
    assert Enum.all?(entries, &(&1.op == :relate and &1.type == :implements))
    # A citation is a claim, not a validation (§18): each is proposed.
    assert Enum.all?(Status.derive(c.scans, entries).relations, &(&1.state == :proposed))
    assert candidates(c, entries) == []
  end

  @tag verifies: "suggest-never-confirms"
  test "a pair already related in any state is left alone, never re-confirmed", c do
    [one | _] = candidates(c)
    {:ok, [accepted]} = Suggest.accept([one], c.scans, [], @meta)

    # Validated, as a review leaves it (§18).
    related =
      Entry.new!(
        at: accepted.at,
        op: :relate,
        type: accepted.type,
        ends: accepted.ends,
        basis: :review
      )

    assert [%{state: :current}] = Status.derive(c.scans, [related]).relations

    # The item changes: the relation dangles, and suggest must not "fix" it.
    moved =
      Enum.map(c.scans, fn s ->
        if s.id == one.code.id and s.kind == :code, do: %{s | hash: "moved"}, else: s
      end)

    refute {one.spec.id, one.code.id} in pairs(
             Suggest.candidates(c.profile, c.items, moved, [related], @root)
           )

    # Accepting everything suggested leaves it dangling: it is never re-confirmed.
    s = Suggest.all(c.profile, c.items, moved, [related], @root)
    {:ok, recorded} = Suggest.accept_all(s, moved, [related], @meta)
    refute Enum.any?(recorded, &(Entry.relation(&1) == Entry.relation(related)))
    after_accept = Status.derive(moved, [related | recorded]).relations
    key = Entry.relation(related)
    assert %{state: :dangling} = Enum.find(after_accept, &(&1.relation == key))
  end

  # #37: a citation inside a marked block is about the block's requirement.
  @tag :tmp_dir
  test "a citation in a marked block relates the block, not its section", %{tmp_dir: root} do
    File.write!(Path.join(root, "spec.md"), """
    # Limits

    `Wren.send/3` sends.

    <!-- surfex: max-len -->
    `Wren.max_len/0` is 512.
    <!-- /surfex -->
    """)

    items = [
      %Item{kind: :function, name: "send/3", parent: "Wren", file: "lib/w.ex", hash: "00000001"},
      %Item{
        kind: :function,
        name: "max_len/0",
        parent: "Wren",
        file: "lib/w.ex",
        hash: "00000002"
      }
    ]

    scans = Markdown.records(root, ["spec.md"]) ++ Scan.code(items)
    profile = Config.profile!([sources: ["spec.md"]], "Wren")

    assert pairs(Suggest.candidates(profile, items, scans, [], root)) == [
             {"spec.md#Limits", "Wren.send/3"},
             {"spec.md#max-len", "Wren.max_len/0"}
           ]
  end

  # #168: suggest's work grows with the log in proportion, not quadratically. Counted in
  # reductions, not seconds: work done is the same on any machine under any load, where a
  # time bound only catches a regression large enough to beat the noise.
  @tag verifies: "suggest-linear"
  test "suggest's work over twice the relations is about twice, not four times" do
    {config, _} = Code.eval_file(Path.join(@fixture, "surfex.exs"))
    profile = Config.profile!(config, nil)

    # Enough functions that the relations between them, not the fixed costs, dominate.
    items =
      for i <- 1..80,
          do: %Item{
            kind: :function,
            name: "f#{i}/0",
            parent: "Gen",
            file: "lib/gen.ex",
            hash: "h#{i}"
          }

    scans = Markdown.records(@root, ["spec/**/*.md", "notes/**/*.md"]) ++ Scan.code(items)
    ids = for %Scan{kind: :code, id: id, hash: hash} <- scans, do: {id, hash}
    pairs = for {a, ha} <- ids, {b, hb} <- ids, a < b, do: {a, ha, b, hb}

    log = fn n ->
      for {a, ha, b, hb} <- Enum.take(pairs, n) do
        Entry.new!(
          at: "2026-10-09T10:00:00Z",
          op: :relate,
          type: :depends_on,
          ends: [%{kind: :code, id: a, hash: ha}, %{kind: :code, id: b, hash: hb}]
        )
      end
    end

    work = fn n ->
      entries = log.(n)
      {:reductions, before} = Process.info(self(), :reductions)
      Suggest.all(profile, items, scans, entries, @root)
      {:reductions, later} = Process.info(self(), :reductions)
      later - before
    end

    n = 1000
    assert length(pairs) >= 2 * n
    ratio = work.(2 * n) / work.(n)
    assert ratio < 3, "twice the relations took #{Float.round(ratio, 2)}× the work"
  end

  describe "all/5: moves, refines and implements together" do
    @moduletag :tmp_dir

    @wren [
      %Item{kind: :function, name: "send/3", parent: "Wren", file: "lib/w.ex", hash: "00000001"},
      %Item{
        kind: :function,
        name: "max_len/0",
        parent: "Wren",
        file: "lib/w.ex",
        hash: "00000002"
      }
    ]

    @spec_md """
    # Sending

    `Wren.send/3` sends.

    # Limits

    `Wren.max_len/0` is 512.
    """

    defp suggest(root, text, entries) do
      File.write!(Path.join(root, "spec.md"), text)
      scans = Markdown.records(root, ["spec.md"]) ++ Scan.code(@wren)
      profile = Config.profile!([sources: ["spec.md"]], "Wren")
      {Suggest.all(profile, @wren, scans, entries, root), scans}
    end

    defp adopted(root) do
      {s, scans} = suggest(root, @spec_md, [])
      {:ok, entries} = Suggest.accept_all(s, scans, [], @meta)
      entries
    end

    defp summary(s),
      do: %{
        moves: Enum.map(s.moves, &{&1.from, &1.to.id}),
        refines: Enum.map(s.refines, &{&1.from.id, &1.to.id}),
        implements: pairs(s.implements)
      }

    # #153: a function whose arity changed is the commonest code move, and its version
    # changes with it, so the version rule can't see it. Same module, same name, another
    # arity, one to one: suggested; the moved relations dangle, to be judged again.
    @tag verifies: "suggest-code-moves"
    test "a function whose arity changed is suggested as a move; two candidates are ambiguous", %{
      tmp_dir: root
    } do
      entries = adopted(root)
      max_len = Enum.find(@wren, &(&1.name == "max_len/0"))

      arity = fn name, hash ->
        %Item{kind: :function, name: name, parent: "Wren", file: "lib/w.ex", hash: hash}
      end

      profile = Config.profile!([sources: ["spec.md"]], "Wren")

      run = fn items ->
        scans = Markdown.records(root, ["spec.md"]) ++ Scan.code(items)
        {Suggest.all(profile, items, scans, entries, root), scans}
      end

      {s, scans} = run.([arity.("send/4", "00000009"), max_len])
      assert Enum.map(s.moves, &{&1.from, &1.to.id}) == [{"Wren.send/3", "Wren.send/4"}]

      {:ok, moved} = Suggest.accept_all(%{s | implements: [], excuses: []}, scans, entries, @meta)

      states =
        Status.derive(scans, entries ++ moved).relations
        |> Enum.filter(&match?({_, {:code, "Wren.send/4"}, _}, &1.relation))

      # It carries its basis (proposed here) and isn't current: its code end changed.
      assert [%{state: :proposed, changed: [code: "Wren.send/4"]}] = states

      {s, _scans} = run.([arity.("send/4", "00000009"), arity.("send/5", "0000000a"), max_len])
      assert s.moves == []
      assert [%{from: ["Wren.send/3"], to: ["Wren.send/4", "Wren.send/5"]}] = s.ambiguous
    end

    @tag verifies: "suggest-moves"
    test "an added anchor is a move, and nothing is suggested twice", %{tmp_dir: root} do
      entries = adopted(root)

      {s, scans} =
        suggest(root, String.replace(@spec_md, "# Limits", "# Limits {#limits}"), entries)

      assert summary(s) == %{
               moves: [{"spec.md#Limits", "spec.md#limits"}],
               refines: [],
               implements: []
             }

      {:ok, recorded} = Suggest.accept_all(s, scans, entries, @meta)
      status = Status.derive(scans, entries ++ recorded)
      # The move carries each relation as it was: here, proposed (§18).
      assert Enum.frequencies_by(status.relations, & &1.state) == %{proposed: 2, retired: 1}
    end

    # #70: an anchor added to a section whose decisions are all retirements still moves,
    # and suggest goes on honouring them under the new id.
    @tag verifies: "move-carries-retirements"
    test "a retired pair stays declined across an added anchor", %{tmp_dir: root} do
      entries = adopted(root)
      {_s, scans} = suggest(root, @spec_md, entries)
      note = [note: "512 is the wire limit, documented in §2, not here"] ++ @meta

      {:ok, retired} =
        Surfex.Record.retire(
          scans,
          entries,
          "spec.md#Limits",
          "Wren.max_len/0",
          :implements,
          note
        )

      entries = entries ++ retired

      {s, scans} =
        suggest(root, String.replace(@spec_md, "# Limits", "# Limits {#limits}"), entries)

      assert summary(s).moves == [{"spec.md#Limits", "spec.md#limits"}]
      assert summary(s).implements == []

      {:ok, recorded} = Suggest.accept_all(s, scans, entries, @meta)

      {again, _} =
        suggest(
          root,
          String.replace(@spec_md, "# Limits", "# Limits {#limits}"),
          entries ++ recorded
        )

      assert summary(again) == %{moves: [], refines: [], implements: []}
    end

    @tag verifies: "decline-recorded"
    test "a declined suggestion is never suggested again", %{tmp_dir: root} do
      {s, scans} = suggest(root, @spec_md, [])
      assert {"spec.md#Limits", "Wren.max_len/0"} in summary(s).implements

      why = [note: "512 is the wire limit, documented in §2"] ++ @meta

      {:ok, declined} =
        Surfex.Record.retire(scans, [], "spec.md#Limits", "Wren.max_len/0", :implements, why)

      {again, _} = suggest(root, @spec_md, declined)
      refute {"spec.md#Limits", "Wren.max_len/0"} in summary(again).implements
    end

    test "a heading renamed and reworded at once is not a move", %{tmp_dir: root} do
      entries = adopted(root)

      text =
        String.replace(
          @spec_md,
          "# Limits\n\n`Wren.max_len/0` is 512.",
          "# Sizes\n\n`Wren.max_len/0` is 1024."
        )

      {s, _scans} = suggest(root, text, entries)
      assert summary(s).moves == []
      # Its citation is suggested afresh instead; the old relation stays orphaned for review.
      assert summary(s).implements == [{"spec.md#Sizes", "Wren.max_len/0"}]
    end

    @tag verifies: "suggest-moves"
    test "two candidates at one version are ambiguous, and not suggested", %{tmp_dir: root} do
      entries = adopted(root)

      text =
        String.replace(@spec_md, "# Limits", "# Limits A") <>
          "\n# Limits B\n\n`Wren.max_len/0` is 512.\n"

      {s, _scans} = suggest(root, text, entries)
      assert summary(s).moves == []
    end

    # #99: a test file split into sub-modules renames every test in it; each is the same
    # version under a new id, and the move carries its relations and records.
    @tag verifies: "suggest-test-moves"
    test "a test file split into modules is suggested as one move per test, keeping its records",
         %{tmp_dir: root} do
      body = fn n -> "test \"t#{n}\", do: assert(Wren.send(:a, :b, #{n}))" end

      before = "defmodule WrenTest do\n  use ExUnit.Case\n  #{body.(1)}\n  #{body.(2)}\nend\n"

      split =
        "defmodule WrenOneTest do\n  use ExUnit.Case\n  #{body.(1)}\nend\n" <>
          "defmodule WrenTwoTest do\n  use ExUnit.Case\n  #{body.(2)}\nend\n"

      {_s, scans} = suggest(root, @spec_md, [])
      profile = Config.profile!([sources: ["spec.md"]], "Wren")
      old = scans ++ Scan.ExUnit.tests(before, "test/wren_test.exs")

      {:ok, entries} =
        Suggest.accept_all(Suggest.all(profile, @wren, old, [], root), old, [], @meta)

      [t1] = for %Scan{kind: :test, id: "WrenTest: t1"} = t <- old, do: t

      observed =
        Entry.new!(
          at: "2026-09-28T10:30:00Z",
          op: :observe,
          type: :red_green,
          basis: :evidence,
          ends: [%{kind: :test, id: t1.id, hash: t1.hash}]
        )

      entries = entries ++ [observed]
      new = scans ++ Scan.ExUnit.tests(split, "test/wren_test.exs")
      s = Suggest.all(profile, @wren, new, entries, root)

      assert Enum.sort(Enum.map(s.moves, &{&1.from, &1.to.id})) == [
               {"WrenTest: t1", "WrenOneTest: t1"},
               {"WrenTest: t2", "WrenTwoTest: t2"}
             ]

      # The moved tests' relations come by the move, so they aren't suggested afresh.
      assert s.tests == []

      {:ok, recorded} = Suggest.accept_all(s, new, entries, @meta)
      status = Status.derive(new, entries ++ recorded)
      assert MapSet.member?(status.discriminated, {"WrenOneTest: t1", t1.hash})
      refute Enum.any?(status.relations, &(&1.state == :orphaned))
    end

    @tag verifies: "suggest-test-moves"
    test "a test version found under two new ids is ambiguous: reported, not suggested",
         %{tmp_dir: root} do
      body = "test \"t\", do: assert(Wren.send(:a, :b, 1))"
      before = "defmodule WrenTest do\n  use ExUnit.Case\n  #{body}\nend\n"

      twice =
        "defmodule WrenOneTest do\n  use ExUnit.Case\n  #{body}\nend\n" <>
          "defmodule WrenTwoTest do\n  use ExUnit.Case\n  #{body}\nend\n"

      {_s, scans} = suggest(root, @spec_md, [])
      profile = Config.profile!([sources: ["spec.md"]], "Wren")
      old = scans ++ Scan.ExUnit.tests(before, "test/wren_test.exs")

      {:ok, entries} =
        Suggest.accept_all(Suggest.all(profile, @wren, old, [], root), old, [], @meta)

      new = scans ++ Scan.ExUnit.tests(twice, "test/wren_test.exs")
      s = Suggest.all(profile, @wren, new, entries, root)
      assert s.moves == []
      assert [%{from: ["WrenTest: t"], to: ["WrenOneTest: t", "WrenTwoTest: t"]}] = s.ambiguous
    end

    test "blocks and hints refine what they sit in", %{tmp_dir: root} do
      text = """
      # Limits {#limits}

      <!-- surfex: max-len -->
      `Wren.max_len/0` is 512.

      ```test max-len-test
      a 513-byte message is refused
      ```
      <!-- /surfex -->
      """

      {s, _scans} = suggest(root, text, [])

      assert summary(s) == %{
               moves: [],
               refines: [
                 {"spec.md#max-len", "spec.md#limits"},
                 {"spec.md#max-len-test", "spec.md#max-len"}
               ],
               implements: [{"spec.md#max-len", "Wren.max_len/0"}]
             }
    end
  end

  # #148: declining is a `retire` of a never-related pair. `suggest` shows the exact command
  # beside each judgement it proposes, so a decline lands in the log, not a commit message.
  describe "declining" do
    @describetag verifies: "decline-shown"

    test "the command for a judgement candidate, ids kind-prefixed and quoted" do
      assert Suggest.decline_command(
               :implements,
               "spec.md#Carts/Adding items",
               "MyApp.Cart.add/2"
             ) ==
               ~s(mix surfex.retire "spec:spec.md#Carts/Adding items" "code:MyApp.Cart.add/2" --type implements --note "why it isn't one")

      assert Suggest.decline_command(:excuses, "plumbing", "MyApp.Repo.config/0") ==
               ~s(mix surfex.retire "class:plumbing" "code:MyApp.Repo.config/0" --type excuses --note "why it isn't one")
    end

    test "a double quote in an id is escaped" do
      assert Suggest.decline_command(:implements, ~s(spec.md#The "fast" path), "M.f/0") =~
               ~s("spec:spec.md#The \\"fast\\" path")
    end

    test "only judgements are declined; a structural suggestion has no decline" do
      assert Suggest.decline_command(:tests, "T: a", "M.f/0") == nil
      assert Suggest.decline_command(:refines, "spec.md#a", "spec.md#b") == nil
    end
  end

  describe "all/5: verifies and tests" do
    @moduletag :tmp_dir

    test "a declaration proposes verifies; a call to scanned code proposes tests", %{
      tmp_dir: root
    } do
      File.write!(Path.join(root, "spec.md"), "# Limits {#limits}\n\n`Wren.max_len/0` is 512.\n")

      items = [
        %Item{
          kind: :function,
          name: "max_len/0",
          parent: "Wren",
          file: "lib/w.ex",
          hash: "00000002"
        }
      ]

      test_scan = %Scan{
        kind: :test,
        id: "WrenTest: the limit",
        hash: "t1",
        location: %{file: "test/w_test.exs", lines: {3, 5}},
        declares: [{:verifies, "limits"}, {:verifies, "nothing"}],
        calls: ["Wren.max_len/0", "Enum.map/2"]
      }

      scans = Markdown.records(root, ["spec.md"]) ++ Scan.code(items) ++ [test_scan]
      profile = Config.profile!([sources: ["spec.md"]], "Wren")
      s = Suggest.all(profile, items, scans, [], root)

      assert Enum.map(s.verifies, &{&1.from.id, &1.to.id}) == [
               {"WrenTest: the limit", "spec.md#limits"}
             ]

      assert Enum.map(s.tests, &{&1.from.id, &1.to.id}) == [
               {"WrenTest: the limit", "Wren.max_len/0"}
             ]

      {:ok, entries} = Suggest.accept_all(s, scans, [], @meta)
      assert Enum.frequencies_by(entries, & &1.type) == %{implements: 1, verifies: 1, tests: 1}
      status = Status.derive(scans, entries)
      assert status.triangle == []

      # The tag goes: suggest retires the verifies relation the test no longer declares.
      dropped = Enum.map(scans, fn s -> if s.kind == :test, do: %{s | declares: []}, else: s end)
      s2 = Suggest.all(profile, items, dropped, entries, root)
      assert [%{test: "WrenTest: the limit", spec: "spec.md#limits"}] = s2.undeclared

      {:ok, [retired]} =
        Suggest.accept_all(%{s2 | tests: [], implements: []}, dropped, entries, @meta)

      assert %{
               op: :retire,
               type: :verifies,
               note: "the test no longer declares that it verifies this"
             } = retired

      assert Status.derive(dropped, entries ++ [retired]).undeclared == []

      assert Suggest.all(profile, items, scans, entries, root) |> Map.values() |> List.flatten() ==
               []
    end

    @tag verifies: "suggest-refresh"
    test "a structural relation the source still states is refreshed; a judgement is not", %{
      tmp_dir: root
    } do
      File.write!(Path.join(root, "spec.md"), "# Limits {#limits}\n\n`Wren.max_len/0` is 512.\n")

      item = %Item{
        kind: :function,
        name: "max_len/0",
        parent: "Wren",
        file: "lib/w.ex",
        hash: "c1"
      }

      test_scan = %Scan{
        kind: :test,
        id: "WrenTest: the limit",
        hash: "t1",
        location: %{file: "test/w_test.exs", lines: {3, 5}},
        calls: ["Wren.max_len/0"]
      }

      profile = Config.profile!([sources: ["spec.md"]], "Wren")
      scans = Markdown.records(root, ["spec.md"]) ++ Scan.code([item]) ++ [test_scan]

      {:ok, accepted} =
        Suggest.accept_all(Suggest.all(profile, [item], scans, [], root), scans, [], @meta)

      # The implements relation validated, as a review leaves it (§18).
      entries =
        Enum.map(accepted, fn
          %{type: :implements} = e ->
            Entry.new!(at: e.at, op: e.op, type: e.type, ends: e.ends, basis: :review)

          e ->
            e
        end)

      assert Enum.all?(Status.derive(scans, entries).relations, &(&1.state == :current))

      # The code and the test both change; the test still calls the code.
      changed = %{item | hash: "c2"}

      scans2 =
        Markdown.records(root, ["spec.md"]) ++ Scan.code([changed]) ++ [%{test_scan | hash: "t2"}]

      s = Suggest.all(profile, [changed], scans2, entries, root)

      assert Enum.map(s.refresh, &{&1.type, &1.from.id, &1.to.id}) == [
               {:tests, "WrenTest: the limit", "Wren.max_len/0"}
             ]

      {:ok, recorded} = Suggest.accept_all(s, scans2, entries, @meta)
      states = Map.new(Status.derive(scans2, entries ++ recorded).relations, &{&1.type, &1.state})
      # The implements relation dangles on the changed code and is not refreshed: only
      # evidence or a review settles it.
      assert states == %{tests: :current, implements: :dangling}

      # A test that no longer calls the code states nothing: no refresh.
      gone =
        Markdown.records(root, ["spec.md"]) ++
          Scan.code([changed]) ++ [%{test_scan | hash: "t2", calls: []}]

      assert Suggest.all(profile, [changed], gone, entries, root).refresh == []
    end
  end
end
