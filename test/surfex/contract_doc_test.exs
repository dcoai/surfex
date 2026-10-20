defmodule Surfex.ContractDocTest do
  # #332 (for #325): a contract relation records its code's doc version and dangles when
  # the doc changes (spec §12.1, §13.18).
  use ExUnit.Case, async: true

  alias Surfex.{Record, Scan, Status}
  alias Surfex.Log.Entry
  alias Surfex.Status.Report

  @code "M.add/2"
  @contract "spec.md#add-contract"
  @section "spec.md#carts"
  @t "T: adds"
  @meta [by: "tester", commit: "abc", at: "2026-10-20T10:00:00Z"]

  defp cdoc_scan(kind, id, hash, fields),
    do:
      struct!(
        %Scan{kind: kind, id: id, hash: hash, location: %{file: "f", lines: {1, 2}}},
        fields
      )

  # The world: a function, a contract unit stating it inside a section, and a test that
  # verifies the contract and calls the function.
  defp cdoc_world(opts \\ []) do
    [
      cdoc_scan(:code, @code, Keyword.get(opts, :code, "c1"), doc: Keyword.get(opts, :doc, "d1")),
      cdoc_scan(:spec, @section, "s1", role: :section),
      cdoc_scan(:spec, @contract, "k1", role: :contract, contract: @code, within: @section),
      cdoc_scan(:test, @t, "t1", declares: [{:verifies, @contract}], calls: [@code])
    ]
  end

  # A relation as the process leaves it: recorded by Record, then on a validating basis.
  defp cdoc_validated(scans, to, basis \\ :review) do
    {:ok, [e]} = Record.relate(scans, [], to, @code, :implements, @meta)
    Entry.new!(e |> Map.from_struct() |> Map.put(:basis, basis))
  end

  defp cdoc_code_end(%Entry{ends: ends}), do: Enum.find(ends, &(&1.kind == :code))

  defp cdoc_relation(status, unit),
    do:
      Enum.find(status.relations, &(&1.relation == {:implements, {:code, @code}, {:spec, unit}}))

  describe "the log" do
    @describetag verifies: "doc-entry"

    @tag verifies: ["doc-entry", "log-entries"]
    test "doc is written on a code end only when set, so an end without it keeps its line and id" do
      fields = [
        at: "2026-10-20T10:00:00Z",
        op: :relate,
        type: :implements,
        basis: :review,
        ends: [%{kind: :code, id: @code, hash: "c1"}, %{kind: :spec, id: @contract, hash: "k1"}]
      ]

      plain = Entry.new!(fields)
      refute Entry.encode(plain) =~ "doc"

      with_doc =
        Entry.new!(
          Keyword.put(fields, :ends, [
            %{kind: :code, id: @code, hash: "c1", doc: "d1"},
            %{kind: :spec, id: @contract, hash: "k1"}
          ])
        )

      line = Entry.encode(with_doc)
      assert line =~ ~s("kind":"code","id":"M.add/2","hash":"c1","doc":"d1")
      refute with_doc.id == plain.id
      assert Entry.decode!(line) == with_doc
      assert Map.get(cdoc_code_end(Entry.decode!(Entry.encode(plain))), :doc) == nil

      # Only an implements' code end carries one, and never a blank one.
      assert {:error, "only an implements' code end carries doc" <> _} =
               Entry.build(
                 Keyword.put(fields, :ends, [
                   %{kind: :code, id: @code, hash: "c1"},
                   %{kind: :spec, id: @contract, hash: "k1", doc: "d1"}
                 ])
               )

      assert {:error, "only an implements' code end carries doc" <> _} =
               Entry.build(
                 type: :tests,
                 op: :relate,
                 ends: [
                   %{kind: :test, id: @t, hash: "t1"},
                   %{kind: :code, id: @code, hash: "c1", doc: "d1"}
                 ]
               )

      assert {:error, _} =
               Entry.build(
                 Keyword.put(fields, :ends, [
                   %{kind: :code, id: @code, hash: "c1", doc: " "},
                   %{kind: :spec, id: @contract, hash: "k1"}
                 ])
               )
    end
  end

  describe "status" do
    @describetag verifies: "contract-doc-dangles"

    @tag verifies: ["contract-doc-dangles", "contract-doc-versions"]
    test "a contract relation records the doc version and dangles when it changes; a section's doesn't" do
      world = cdoc_world()
      contract = cdoc_validated(world, @contract)
      section = cdoc_validated(world, @section)

      assert %{doc: "d1", hash: "c1"} = cdoc_code_end(contract)
      refute Map.has_key?(cdoc_code_end(section), :doc)

      assert %{state: :current, doc_changed: []} =
               cdoc_relation(Status.derive(world, [contract, section]), @contract)

      redoc = Status.derive(cdoc_world(doc: "d2"), [contract, section])

      assert %{state: :dangling, changed: [], doc_changed: [{:code, @code}]} =
               cdoc_relation(redoc, @contract)

      assert %{state: :current} = cdoc_relation(redoc, @section)
      assert Status.failing?(redoc)

      # Code and doc both moved: each named apart.
      both = Status.derive(cdoc_world(doc: "d2", code: "c2"), [contract, section])

      assert %{state: :dangling, changed: [{:code, @code}], doc_changed: [{:code, @code}]} =
               cdoc_relation(both, @contract)

      # The report says which end moved.
      text = Report.text(redoc)
      assert text =~ "↔ spec #{@contract} (doc changed: #{@code} (f:1-2))"
      refute text =~ "#{@contract} (changed:"

      [json] =
        for r <- (redoc |> Report.json() |> :json.decode())["relations"],
            Enum.any?(r["ends"], &(&1["id"] == @contract)),
            do: r

      assert %{"changed" => false, "doc_changed" => true} =
               Enum.find(json["ends"], &(&1["kind"] == "code"))
    end

    @tag verifies: ["contract-doc-unrecorded", "contract-doc-versions"]
    test "a relation recorded without a doc version doesn't dangle on a doc edit and is counted" do
      world = cdoc_world()

      legacy =
        Entry.new!(
          at: "2026-10-01T10:00:00Z",
          op: :relate,
          type: :implements,
          basis: :review,
          ends: [%{kind: :code, id: @code, hash: "c1"}, %{kind: :spec, id: @contract, hash: "k1"}]
        )

      status = Status.derive(cdoc_world(doc: "d2"), [legacy])
      assert %{state: :current, doc_changed: []} = cdoc_relation(status, @contract)
      assert status.doc_unrecorded == [{:implements, {:code, @code}, {:spec, @contract}}]
      assert Report.text(status) =~ "  1 contract relation has no doc version recorded yet\n"

      assert (status |> Report.json() |> :json.decode())["doc_unrecorded"] == [
               %{
                 "type" => "implements",
                 "ends" => [
                   %{"kind" => "code", "id" => @code},
                   %{"kind" => "spec", "id" => @contract}
                 ]
               }
             ]

      # A section relation never wants one, and a recorded one isn't counted.
      section = cdoc_validated(world, @section)
      contract = cdoc_validated(world, @contract)
      assert Status.derive(world, [section, contract]).doc_unrecorded == []
      refute Report.text(Status.derive(world, [section])) =~ "no doc version"

      # The next relate records it.
      {:ok, [again]} = Record.relate(world, [legacy], @contract, @code, :implements, @meta)
      assert %{doc: "d1"} = cdoc_code_end(again)
      assert again.parents == [legacy.id]
    end
  end

  describe "settling a doc change" do
    @describetag verifies: "contract-doc-dangles"

    defp cdoc_run(result, code_hash, n),
      do: %{
        test: @t,
        test_hash: "t1",
        result: result,
        at: "2026-10-20T1#{n}:00:00Z",
        run: "r#{n}",
        seq: 0,
        code: %{@code => code_hash}
      }

    defp cdoc_settled(world) do
      verifies =
        Entry.new!(
          at: "2026-10-20T09:00:00Z",
          op: :relate,
          type: :verifies,
          basis: :evidence,
          ends: [%{kind: :test, id: @t, hash: "t1"}, %{kind: :spec, id: @contract, hash: "k1"}]
        )

      tests =
        Entry.new!(
          at: "2026-10-20T09:00:00Z",
          op: :relate,
          type: :tests,
          ends: [%{kind: :test, id: @t, hash: "t1"}, %{kind: :code, id: @code, hash: "c1"}]
        )

      [cdoc_validated(world, @contract, :evidence), verifies, tests]
    end

    @tag verifies: ["contract-doc-dangles", "contract-doc-versions"]
    test "evidence doesn't settle a doc change; a review records the new doc version" do
      entries = cdoc_settled(cdoc_world())
      evidence = [cdoc_run(:failed, "c0", 1), cdoc_run(:passed, "c1", 2)]

      # A code change alone is evidence's to settle, and it records the doc version.
      {:ok, recorded} =
        Record.confirm_by_evidence(
          cdoc_world(code: "c2"),
          entries,
          [
            cdoc_run(:failed, "c0", 1),
            cdoc_run(:passed, "c2", 3)
          ],
          @meta
        )

      assert [%Entry{basis: :evidence} = carried] =
               Enum.filter(recorded, &(&1.type == :implements))

      assert %{hash: "c2", doc: "d1"} = cdoc_code_end(carried)

      # A doc change is not: a run reads no docstring.
      redoc = cdoc_world(doc: "d2")
      {:ok, recorded} = Record.confirm_by_evidence(redoc, entries, evidence, @meta)
      assert Enum.filter(recorded, &(&1.type == :implements)) == []

      assert %{state: :dangling, doc_changed: [{:code, @code}]} =
               cdoc_relation(Status.derive(redoc, entries), @contract)

      # A review settles it, at the new doc version.
      {:ok, reviewed} =
        Record.validate(redoc, entries, @t, @contract, evidence,
          note: "the reworded @doc still says what the contract states",
          by: "tester",
          at: "2026-10-20T13:00:00Z"
        )

      assert [%Entry{basis: :review} = review] = Enum.filter(reviewed, &(&1.type == :implements))
      assert %{doc: "d2"} = cdoc_code_end(review)

      assert %{state: :current} =
               cdoc_relation(Status.derive(redoc, entries ++ reviewed), @contract)
    end
  end

  describe "through the scanner" do
    @describetag verifies: "contract-doc-dangles"

    @cdoc_source ~S'''
    defmodule M do
      @moduledoc "M."

      @doc """
      Adds two numbers.
      """
      def add(a, b), do: a + b
    end
    '''

    defp cdoc_scanned(source) do
      root = Path.join(System.tmp_dir!(), "surfex_cdoc_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(root, "lib"))
      on_exit(fn -> File.rm_rf!(root) end)
      File.write!(Path.join(root, "lib/m.ex"), source)

      code = root |> Surfex.Scanner.Elixir.items() |> Scan.code()
      code ++ tl(cdoc_world())
    end

    defp cdoc_state(source, entries),
      do: cdoc_relation(Status.derive(cdoc_scanned(source), entries), @contract)

    @tag verifies: ["contract-doc-dangles", "contract-doc-versions"]
    test "rewording, adding or removing a @doc dangles the contract relation; whitespace doesn't" do
      entries = [cdoc_validated(cdoc_scanned(@cdoc_source), @contract)]
      assert %{state: :current} = cdoc_state(@cdoc_source, entries)

      rewrapped =
        String.replace(@cdoc_source, "  Adds two numbers.\n", "    Adds   two\n  numbers.\n")

      assert %{state: :current} = cdoc_state(rewrapped, entries)

      reworded = String.replace(@cdoc_source, "Adds two numbers.", "Sums two numbers.")
      assert %{state: :dangling, changed: [], doc_changed: [_]} = cdoc_state(reworded, entries)

      removed = String.replace(@cdoc_source, ~r/  @doc """\n.*\n  """\n/s, "")
      refute removed =~ "@doc"
      assert %{state: :dangling, changed: [], doc_changed: [_]} = cdoc_state(removed, entries)

      # Adding one to an undocumented function dangles its contract too.
      undocumented = [cdoc_validated(cdoc_scanned(removed), @contract)]
      assert %{state: :current} = cdoc_state(removed, undocumented)

      assert %{state: :dangling, doc_changed: [_]} =
               cdoc_state(@cdoc_source, undocumented)
    end
  end
end
