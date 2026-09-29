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
      assert Entry.ops() == [:relate, :retire]
      assert Entry.types() == [:implements, :refines, :depends_on, :tests, :verifies, :excuses]
      assert Entry.kinds() == [:spec, :code, :test, :config, :class]
      assert Entry.directed() == [:depends_on, :refines, :tests, :verifies]

      a = %{kind: :spec, id: "spec.md#S"}
      b = %{kind: :code, id: "M.f/1"}
      assert Entry.relation(:implements, a, b) == Entry.relation(:implements, b, a)
      refute Entry.relation(:depends_on, a, b) == Entry.relation(:depends_on, b, a)
      assert Entry.json(~s({"hash":null})) == %{"hash" => nil}
    end

    test "a basis is one of four, written only when set, so an entry without one keeps its id" do
      assert Entry.bases() == [:evidence, :review, :judgement, :proposed]

      plain = entry(1)
      refute Entry.encode(plain) =~ "basis"

      for basis <- Entry.bases() do
        e = entry(1, basis: basis)
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
      assert problem =~ "surfex.log: entry"
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
