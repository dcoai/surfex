defmodule Surfex.LogTest do
  use ExUnit.Case, async: true

  alias Surfex.Log
  alias Surfex.Log.Entry

  @moduletag :tmp_dir

  defp entry(n, extra \\ []) do
    Entry.new!(
      [
        at: "2026-09-28T10:00:0#{n}Z",
        op: :relate,
        type: :implements,
        ends: [
          %{kind: :code, id: "M.f#{n}/1", hash: "c#{n}"},
          %{kind: :spec, id: "spec.md#S#{n}", hash: "s#{n}"}
        ],
        by: "tester"
      ] ++ extra
    )
  end

  defp open(root), do: Path.join(Log.dir(root), "surfex.log")

  describe "entries" do
    @describetag verifies: "entry-canonical"

    test "encode and decode round-trip, with keys in a fixed order" do
      e = entry(1, note: "why", parents: ["b", "a"], commit: "abc")
      line = Entry.encode(e)

      assert line =~
               ~r/^\{"id":"[0-9a-f]{64}","at":"2026-09-28T10:00:01Z","commit":"abc","parents":\["a","b"\],"op":"relate"/

      assert Entry.decode!(line) == e
    end

    test "the id is stable and changes with any field" do
      assert entry(1).id == entry(1).id
      refute entry(1).id == entry(1, note: "x").id
      refute entry(1).id == entry(1, at: "2026-09-28T11:00:00Z").id
    end

    test "ends are sorted, so A↔B and B↔A are one relation" do
      a = %{kind: :spec, id: "spec.md#S", hash: "s"}
      b = %{kind: :code, id: "M.f/1", hash: "c"}
      base = [at: "2026-09-28T10:00:00Z", op: :relate, type: :implements]
      assert Entry.new!(base ++ [ends: [a, b]]) == Entry.new!(base ++ [ends: [b, a]])

      assert Entry.relation(Entry.new!(base ++ [ends: [a, b]])) ==
               {:implements, {:code, "M.f/1"}, {:spec, "spec.md#S"}}
    end

    test "invalid fields are named" do
      assert {:error, msg} =
               Entry.build(at: "2026-09-28T10:00:00Z", op: :delete, type: :implements, ends: [])

      assert msg =~ ":ends" or msg =~ ":op"

      assert_raise ArgumentError, ~r/:type/, fn ->
        Entry.new!(at: "2026-09-28T10:00:00Z", op: :relate, type: :likes, ends: entry(1).ends)
      end
    end

    test "the vocabulary is fixed: ops, types, kinds, and which types are directed" do
      assert Entry.ops() == [:relate, :retire, :mark, :observe]
      assert Entry.types() == [:implements, :refines, :depends_on, :tests, :verifies, :excuses]
      assert Entry.kinds() == [:spec, :code, :test, :class]
      assert Entry.directed() == [:depends_on, :refines, :tests, :verifies]

      a = %{kind: :spec, id: "spec.md#S"}
      b = %{kind: :code, id: "M.f/1"}
      assert Entry.relation(:implements, a, b) == Entry.relation(:implements, b, a)
      refute Entry.relation(:depends_on, a, b) == Entry.relation(:depends_on, b, a)
      assert Entry.json(~s({"hash":null})) == %{"hash" => nil}
    end

    test "a basis is one of a fixed set, written only when set, so an entry without one keeps its id" do
      assert Entry.bases() == [:evidence, :review, :judgement, :baseline, :proposed]

      # verifies may carry every basis (the grammar limits the others, §12.1).
      verifies = fn extra ->
        Entry.new!(
          [
            at: "2026-09-28T10:00:01Z",
            op: :relate,
            type: :verifies,
            ends: [
              %{kind: :test, id: "T: t", hash: "t1"},
              %{kind: :spec, id: "spec.md#S1", hash: "s1"}
            ]
          ] ++ extra
        )
      end

      plain = verifies.([])
      refute Entry.encode(plain) =~ "basis"

      for basis <- Entry.bases() do
        e = verifies.(basis: basis)
        assert Entry.encode(e) =~ ~s("basis":"#{basis}")
        assert Entry.decode!(Entry.encode(e)) == e
        refute e.id == plain.id
      end

      assert_raise ArgumentError, ~r/:basis/, fn -> entry(1, basis: :hunch) end
    end

    test "a planned end has no hash, written as null; two planned ends are refused" do
      planned = [
        %{kind: :code, id: "M.later/1", hash: nil},
        %{kind: :spec, id: "spec.md#S", hash: "s"}
      ]

      e = Entry.new!(at: "2026-09-28T10:00:00Z", op: :relate, type: :implements, ends: planned)
      line = Entry.encode(e)
      assert line =~ ~s({"kind":"code","id":"M.later/1","hash":null})
      assert Entry.decode!(line) == e

      assert {:error, msg} =
               Entry.build(
                 at: "2026-09-28T10:00:00Z",
                 op: :relate,
                 type: :implements,
                 ends: Enum.map(planned, &%{&1 | hash: nil})
               )

      assert msg =~ ":ends"
    end

    # #93: a test version's discrimination is a fact the log keeps, on one test end.
    test "an observation is one test end at its version, op observe, type red_green" do
      test_end = %{kind: :test, id: "T: a", hash: "t1"}

      base = [
        at: "2026-09-28T10:00:01Z",
        op: :observe,
        type: :red_green,
        basis: :evidence,
        note: "failed at …, passed at …"
      ]

      seen = Entry.new!(base ++ [ends: [test_end]])
      assert Entry.observation_types() == [:red_green, :baseline]
      assert :observe in Entry.ops()
      refute Entry.relation?(seen)
      assert Entry.relation?(entry(1))
      refute Entry.mark?(seen)
      assert Entry.decode!(Entry.encode(seen)) == seen

      # One test end at a version; nothing else is an observation.
      spec = %{kind: :spec, id: "spec.md#S1", hash: "s1"}

      assert_raise ArgumentError, ~r/red_green ends must be one test/, fn ->
        Entry.new!(base ++ [ends: [spec]])
      end

      assert_raise ArgumentError, ~r/:ends/, fn ->
        Entry.new!(base ++ [ends: [%{test_end | hash: nil}]])
      end

      assert_raise ArgumentError, ~r/:type/, fn ->
        Entry.new!(Keyword.put(base, :op, :relate) ++ [ends: [test_end, spec]])
      end
    end

    # #73: a mark says the spec unit itself needs to change. It has one end.
    @tag verifies: "mark-entry"
    test "a mark is one spec end, op mark, type needs_update; relations keep their ids" do
      unit = %{kind: :spec, id: "spec.md#S1", hash: "s1"}
      base = [at: "2026-09-28T10:00:01Z", op: :mark, type: :needs_update, note: "too slow"]
      mark = Entry.new!(base ++ [ends: [unit]])

      assert Entry.mark?(mark)
      refute Entry.mark?(entry(1))
      assert Entry.mark_types() == [:needs_update]
      assert :mark in Entry.ops()
      refute :needs_update in Entry.types()
      assert Entry.relation(mark) == {:needs_update, {:spec, "spec.md#S1"}}
      assert Entry.decode!(Entry.encode(mark)) == mark

      # One end, and it is a spec unit; a relation's type can't be a mark, nor the reverse.
      code = %{kind: :code, id: "M.f/1", hash: "c1"}

      for ends <- [[unit, code], [code]] do
        assert_raise ArgumentError, ~r/needs_update ends must be one spec/, fn ->
          Entry.new!(base ++ [ends: ends])
        end
      end

      assert_raise ArgumentError, ~r/:type/, fn ->
        Entry.new!(Keyword.put(base, :type, :implements) ++ [ends: [unit]])
      end

      assert_raise ArgumentError, ~r/:type/, fn ->
        Entry.new!(at: base[:at], op: :relate, type: :needs_update, ends: [unit, code])
      end

      # Withdrawing is a retire of the mark: same type and end, the mark as parent.
      withdrawn =
        Entry.new!(
          at: "2026-09-28T11:00:00Z",
          op: :retire,
          type: :needs_update,
          ends: [unit],
          parents: [mark.id]
        )

      assert Entry.mark?(withdrawn)

      # Entries from before marks existed are unchanged: this id was computed before.
      assert entry(1).id == "3b1ab3f7ab2d842901c79e8a11f9d92d0bbd9be370123640ed59a1587adcf6b8"
    end

    @tag verifies: "log-entries"
    test "decode says why a line isn't an entry; text that isn't JSON raises" do
      line = Entry.encode(entry(1))
      map = Entry.json(line)

      missing = map |> Map.delete("op") |> :json.encode() |> IO.iodata_to_binary()
      assert {:error, msg} = Entry.decode(missing)
      assert msg =~ "op"

      unknown = map |> Map.put("type", "likes") |> :json.encode() |> IO.iodata_to_binary()
      assert {:error, msg} = Entry.decode(unknown)
      assert msg =~ "type"

      assert_raise ArgumentError, ~r/field op is invalid/, fn -> Entry.decode!(missing) end
      assert_raise ErlangError, fn -> Entry.decode("{not json") end
    end

    @tag verifies: "entry-tamper"
    test "an edited line no longer decodes as its id" do
      line = entry(1) |> Entry.encode() |> String.replace(~s("hash":"c1"), ~s("hash":"cX"))
      assert {:error, msg} = Entry.decode(line)
      assert msg =~ "does not match its content"
    end
  end

  # #90: what a well-formed entry is, enforced at build and decode, not left to the writers.
  describe "the entry grammar" do
    defp e(op, type, ends, basis \\ nil) do
      Entry.build(
        at: "2026-10-02T10:00:00Z",
        op: op,
        type: type,
        ends: for({kind, id} <- ends, do: %{kind: kind, id: id, hash: "h-#{id}"}),
        basis: basis
      )
    end

    @tag verifies: "grammar-ends"
    test "each type joins its kinds of end, and a directed one only from → to" do
      for {type, ends} <- [
            implements: [code: "M.f/1", spec: "s#a"],
            verifies: [test: "T: t", spec: "s#a"],
            tests: [test: "T: t", code: "M.f/1"],
            refines: [spec: "s#a", spec: "s#b"],
            depends_on: [code: "M.f/1", code: "M.g/1"],
            excuses: [class: "generated", code: "M.f/1"]
          ] do
        assert {:ok, _} = e(:relate, type, ends), "#{type} refused its own ends"
        assert {:ok, _} = e(:retire, type, ends)
      end

      assert {:error, "implements ends must be code ↔ spec, got test, test"} =
               e(:relate, :implements, test: "T: a", test: "T: b")

      assert {:error, "verifies ends must be test → spec, got spec, test"} =
               e(:relate, :verifies, spec: "s#a", test: "T: t")

      assert {:error, "tests ends must be test → code, got code, test"} =
               e(:retire, :tests, code: "M.f/1", test: "T: t")

      assert {:error, "excuses ends must be class ↔ code, got class, spec"} =
               e(:relate, :excuses, class: "generated", spec: "s#a")

      assert {:error, "needs_update ends must be one spec, got code"} =
               e(:mark, :needs_update, code: "M.f/1")

      assert {:error, "red_green ends must be one test, got spec"} =
               e(:observe, :red_green, [spec: "s#a"], :evidence)

      # Nothing records a config end: it is no kind.
      assert {:error, msg} = e(:relate, :depends_on, config: "x", code: "M.f/1")
      assert msg =~ "depends_on ends must be code → code"
    end

    @tag verifies: "grammar-bases"
    test "each type carries only its bases; a retire and a mark carry none" do
      ok = fn type, ends, bases ->
        for basis <- bases,
            do: assert({:ok, _} = e(:relate, type, ends, basis), "#{type} #{basis}")
      end

      code_spec = [code: "M.f/1", spec: "s#a"]
      test_spec = [test: "T: t", spec: "s#a"]
      ok.(:implements, code_spec, [nil, :proposed, :evidence, :review, :baseline])
      ok.(:verifies, test_spec, [nil, :proposed, :evidence, :review, :judgement, :baseline])
      ok.(:tests, [test: "T: t", code: "M.f/1"], [nil, :evidence, :judgement, :baseline])
      ok.(:refines, [spec: "s#a", spec: "s#b"], [nil, :judgement])
      ok.(:depends_on, [code: "M.f/1", code: "M.g/1"], [nil, :judgement])
      # A basis-less excuses is legacy, from before bases (0.4), as for implements and verifies.
      ok.(:excuses, [class: "generated", code: "M.f/1"], [nil, :proposed, :judgement])

      # Code is validated by evidence or a review, never asserted (§18).
      assert {:error, "implements can't carry basis judgement" <> _} =
               e(:relate, :implements, code_spec, :judgement)

      assert {:error, "refines can't carry basis proposed" <> _} =
               e(:relate, :refines, [spec: "s#a", spec: "s#b"], :proposed)

      assert {:error, "a retire carries no basis, got review"} =
               e(:retire, :verifies, test_spec, :review)

      assert {:error, "a mark carries no basis, got judgement"} =
               e(:mark, :needs_update, [spec: "s#a"], :judgement)

      assert {:ok, _} = e(:observe, :red_green, [test: "T: t"], :evidence)
      assert {:ok, _} = e(:observe, :baseline, [test: "T: t"], :baseline)

      assert {:error, "red_green can't carry basis review" <> _} =
               e(:observe, :red_green, [test: "T: t"], :review)

      assert {:error, "baseline can't carry no basis" <> _} =
               e(:observe, :baseline, test: "T: t")
    end

    @tag verifies: "grammar-loud"
    test "a line breaking the grammar is refused at decode, naming the entry and the rule, and --verify lists it with its line",
         %{tmp_dir: root} do
      # A well-formed line, then the same with its basis forged: a valid id over bad content.
      {:ok, good} = e(:relate, :implements, [code: "M.f/1", spec: "s#a"], :review)

      forged =
        Entry.encode(good)
        |> Entry.json()
        |> Map.put("basis", "judgement")
        |> then(fn map ->
          content = map |> Map.delete("id")
          # Rebuild the canonical line by hand, as a hand edit or another tool might.
          id =
            :crypto.hash(:sha256, canonical(content)) |> Base.encode16(case: :lower)

          canonical(Map.put(content, "id", id))
        end)

      assert {:error, "entry " <> rest} = Entry.decode(forged)
      assert rest =~ ": implements can't carry basis judgement"

      Log.init(root)
      Log.append(root, [entry(1)])
      File.write!(open(root), forged <> "\n", [:append])

      assert [problem] = Log.verify(root)

      assert problem =~
               ~r/^surfex\.log:\d+: entry [0-9a-f]{12}: implements can't carry basis judgement/
    end

    @tag verifies: "grammar-loud"
    test "every entry in surfex's own log fits the grammar, with its id unchanged" do
      lines =
        Path.wildcard(Path.expand("../../.surfex/*.log", __DIR__))
        |> Enum.flat_map(&String.split(File.read!(&1), "\n", trim: true))
        |> Enum.reject(&String.starts_with?(&1, ~s({"segment")))

      assert length(lines) > 7000

      for line <- lines do
        assert {:ok, entry} = Entry.decode(line)
        assert Entry.encode(entry) == line
      end
    end

    # The canonical key order (§12.1), for forging a line in a test.
    defp canonical(map) do
      keys = ~w(id at commit parents op type ends by note basis)

      pairs =
        for k <- keys, Map.has_key?(map, k), not (k == "basis" and is_nil(map[k])) do
          [:json.encode(k), ":", encode(k, map[k])]
        end

      IO.iodata_to_binary(["{", Enum.intersperse(pairs, ","), "}"])
    end

    defp encode("ends", ends),
      do: [
        "[",
        ends
        |> Enum.map(
          &[
            "{",
            ~s("kind":),
            :json.encode(&1["kind"]),
            ~s(,"id":),
            :json.encode(&1["id"]),
            ~s(,"hash":),
            (&1["hash"] && :json.encode(&1["hash"])) || "null",
            "}"
          ]
        )
        |> Enum.intersperse(","),
        "]"
      ]

    defp encode(_k, nil), do: "null"
    defp encode(_k, v), do: :json.encode(v)
  end

  describe "the log" do
    @describetag verifies: "log-append-only"

    test "init creates the log and the union merge, idempotently", %{tmp_dir: root} do
      File.write!(Path.join(root, ".gitattributes"), "*.bin binary")
      Log.init(root)
      Log.init(root)

      assert File.read!(Path.join(root, ".gitattributes")) ==
               "*.bin binary\n.surfex/*.log merge=union\n"

      assert File.read!(open(root)) == ~s({"segment":1,"previous":null}\n)
      assert Log.load(root) == []
    end

    @tag verifies: "relation-log"
    test "append then load, ordered by time", %{tmp_dir: root} do
      Log.init(root)
      Log.append(root, [entry(3), entry(1)])
      Log.append(root, [entry(2)])

      assert Enum.map(Log.load(root), & &1.at)
             |> Enum.map(&String.last(String.trim_trailing(&1, "Z"))) == ~w(1 2 3)

      # Entries recorded at one time come in id order, whatever order they were appended.
      [a, b] = Enum.sort_by([entry(4, note: "a"), entry(4, note: "b")], & &1.id)
      Log.append(root, [b, a])
      assert root |> Log.load() |> Enum.take(-2) |> Enum.map(& &1.id) == [a.id, b.id]
    end

    test "append without a log says how to make one", %{tmp_dir: root} do
      assert_raise ArgumentError, ~r/mix surfex.log --init/, fn ->
        Log.append(root, [entry(1)])
      end
    end

    test "segments load together, and duplicates are dropped", %{tmp_dir: root} do
      Log.init(root)
      Log.append(root, [entry(1), entry(2)])
      Log.break(root)
      Log.append(root, [entry(3), entry(2)])
      assert Log.dir(root) == Path.join(root, ".surfex")
      assert File.exists?(Path.join(Log.dir(root), "surfex_1.log"))
      assert length(Log.load(root)) == 3
      assert Log.verify(root) == []

      # The new segment's header chains to the closed one: SHA-256 of its sorted ids.
      previous =
        [entry(1).id, entry(2).id]
        |> Enum.sort()
        |> Enum.join("\n")
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      [header | _] =
        root |> Log.dir() |> Path.join("surfex.log") |> File.read!() |> String.split("\n")

      assert Surfex.Log.Entry.json(header) == %{"segment" => 2, "previous" => previous}
    end
  end

  describe "verify" do
    @describetag verifies: "log-append-only"

    setup %{tmp_dir: root} do
      Log.init(root)
      first = entry(1)
      Log.append(root, [first, entry(2, parents: [first.id])])
      Log.break(root)
      Log.append(root, [entry(3)])
      %{first: first}
    end

    test "a clean log verifies", %{tmp_dir: root} do
      assert Log.verify(root) == []
    end

    test "an edited line is caught", %{tmp_dir: root} do
      path = Path.join(Log.dir(root), "surfex.log")
      File.write!(path, String.replace(File.read!(path), ~s("hash":"c3"), ~s("hash":"cX")))
      assert [problem] = Log.verify(root)
      assert problem =~ ~r/^surfex\.log:\d+: entry/
      assert problem =~ "does not match its content"
    end

    test "a removed parent is caught", %{tmp_dir: root, first: first} do
      path = Path.join(Log.dir(root), "surfex_1.log")

      kept =
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.reject(&String.contains?(&1, first.id <> ~s(","at")))

      File.write!(path, Enum.join(kept, "\n"))
      problems = Log.verify(root)
      assert Enum.any?(problems, &(&1 =~ "names parent #{String.slice(first.id, 0, 12)}"))
    end

    test "a truncated segment breaks the chain, and rechain accepts the segments as they are",
         %{tmp_dir: root} do
      path = Path.join(Log.dir(root), "surfex_1.log")
      [header, keep | _] = path |> File.read!() |> String.split("\n")
      File.write!(path, header <> "\n" <> keep <> "\n")
      assert Enum.any?(Log.verify(root), &(&1 =~ "does not match the segments before it"))

      Log.rechain(root)
      assert Log.verify(root) == []
      assert length(Log.load(root)) == 2
    end
  end

  # The claim the whole design leans on: git's union merge of two branches' appends loads
  # to the same state, with nothing lost and no conflict.
  @tag verifies: "union-merge"
  test "two branches' appends merge without conflict and load to one state", %{tmp_dir: root} do
    git = fn args ->
      {out, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
      out
    end

    git.(["init", "--quiet", "-b", "main"])
    git.(["config", "user.name", "T"])
    git.(["config", "user.email", "t@example.com"])
    Log.init(root)
    Log.append(root, [entry(1)])
    git.(["add", "-A"])
    git.(["commit", "--quiet", "-m", "base"])

    git.(["checkout", "--quiet", "-b", "a"])
    Log.append(root, [entry(2)])
    git.(["commit", "--quiet", "-am", "a"])

    git.(["checkout", "--quiet", "main"])
    Log.append(root, [entry(3)])
    git.(["commit", "--quiet", "-am", "main"])

    git.(["merge", "--quiet", "--no-edit", "a"])
    assert Enum.map(Log.load(root), & &1.id) == Enum.map([entry(1), entry(2), entry(3)], & &1.id)
    assert Log.verify(root) == []
  end
end
