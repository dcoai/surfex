defmodule Surfex.ClassesTest do
  use ExUnit.Case, async: true

  alias Surfex.{Item, Profile, Scan, Status, Suggest}
  alias Surfex.Status.Config
  alias Surfex.Scan.{Classes, Markdown}

  @meta [by: "tester", at: "2026-09-28T10:00:00Z"]

  @config [
    classes: [{"plumbing", "process wiring, not behaviour"}, {"members", "covered by the parent"}],
    rules: [
      %{class: "plumbing", kinds: [:function], name: ~r/^handle_/},
      %{class: "members", kinds: [:field], parent_cited: true}
    ]
  ]

  defp hash(config, class),
    do: config |> Classes.records() |> Enum.find(&(&1.id == class)) |> Map.fetch!(:hash)

  describe "class records" do
    test "one per class, located in .surfex.exs" do
      assert [
               %Scan{kind: :class, id: "members", location: %{file: ".surfex.exs", lines: nil}},
               %Scan{kind: :class, id: "plumbing"}
             ] = Classes.records(@config)
    end

    test "the version covers the reason and the class's rules, not their order" do
      base = hash(@config, "plumbing")

      reason =
        put_in(@config[:classes], [{"plumbing", "wiring"}, {"members", "covered by the parent"}])

      assert hash(reason, "plumbing") != base

      for change <- [
            %{kinds: [:function, :macro]},
            %{name: ~r/^handle_call/},
            %{parent_cited: true}
          ] do
        rules = List.update_at(@config[:rules], 0, &Map.merge(&1, change))
        assert hash(Keyword.put(@config, :rules, rules), "plumbing") != base
      end

      assert hash(Keyword.put(@config, :rules, Enum.reverse(@config[:rules])), "plumbing") == base
      # Another class's rules are not this one's.
      rules = List.update_at(@config[:rules], 1, &Map.put(&1, :kinds, [:field, :const]))
      assert hash(Keyword.put(@config, :rules, rules), "plumbing") == base
    end

    test "the profile's checks apply" do
      assert_raise ArgumentError, ~r/names class "nope", which :classes lacks/, fn ->
        Profile.coverage!(classes: [], rules: [%{class: "nope", kinds: [:function]}])
      end

      assert_raise ArgumentError, ~r/can never be excused/, fn ->
        Profile.coverage!(Keyword.put(@config, :never_excused, [:field]))
      end
    end
  end

  describe "excuse suggestions" do
    @moduletag :tmp_dir

    @items [
      %Item{
        kind: :function,
        name: "handle_call/3",
        parent: "App.Server",
        file: "lib/s.ex",
        hash: "00000001"
      },
      %Item{
        kind: :function,
        name: "handle_info/2",
        parent: "App.Server",
        file: "lib/s.ex",
        hash: "00000002"
      },
      %Item{
        kind: :function,
        name: "start/0",
        parent: "App.Server",
        file: "lib/s.ex",
        hash: "00000003"
      },
      %Item{kind: :struct, name: "App.Msg", file: "lib/m.ex", hash: "00000004"},
      %Item{kind: :field, name: "body", parent: "App.Msg", file: "lib/m.ex", hash: "00000005"},
      %Item{kind: :struct, name: "App.Other", file: "lib/m.ex", hash: "00000006"},
      %Item{kind: :field, name: "x", parent: "App.Other", file: "lib/m.ex", hash: "00000007"}
    ]

    # `handle_info/2` is described by the spec, so it is implemented, not excused. So is
    # `App.Msg`, which lets its field be excused as a member; `App.Other`'s can't be.
    @spec_md "# Server\n\n`App.Server.start/0` and `App.Server.handle_info/2`.\n\n# Messages\n\n`App.Msg` carries one.\n"

    defp suggest(root, config \\ @config, entries \\ []) do
      File.write!(Path.join(root, "spec.md"), @spec_md)
      profile = Config.profile!([sources: ["spec.md"]] ++ config, "App")
      scans = Markdown.records(root, ["spec.md"]) ++ Scan.code(@items) ++ Classes.records(config)
      {Suggest.all(profile, @items, scans, entries, root), scans}
    end

    defp excuses(s), do: s.excuses |> Enum.map(&{&1.from.id, &1.to.id}) |> Enum.sort()

    test "the first matching rule excuses what nothing implements", %{tmp_dir: root} do
      {s, _} = suggest(root)
      assert excuses(s) == [{"members", "App.Msg.body"}, {"plumbing", "App.Server.handle_call/3"}]
    end

    test "accepted, they meet require: [code: [:implements, :excuses]], and a class edit dangles them",
         %{tmp_dir: root} do
      {s, scans} = suggest(root)
      {:ok, entries} = Suggest.accept_all(s, scans, [], @meta)

      status = Status.derive(scans, entries, code: [:implements, :excuses])
      # Only App.Other and its field remain: neither described nor excusable.
      assert Enum.map(status.unmet, & &1.scan.id) == ["App.Other", "App.Other.x"]

      {s, _} = suggest(root, @config, entries)
      assert excuses(s) == []

      reworded =
        put_in(@config[:classes], [
          {"plumbing", "OTP wiring"},
          {"members", "covered by the parent"}
        ])

      {_, rescans} = suggest(root, reworded, entries)

      dangling =
        for %{state: :dangling, relation: {:excuses, {:class, c}, {:code, i}}} <-
              Status.derive(rescans, entries).relations,
            do: {c, i}

      assert dangling == [{"plumbing", "App.Server.handle_call/3"}]
    end

    test "never_excused kinds are never proposed", %{tmp_dir: root} do
      config = [
        classes: [{"all", "everything"}],
        rules: [%{class: "all", kinds: [:function]}],
        never_excused: [:struct]
      ]

      {s, _} = suggest(root, config)
      assert excuses(s) == [{"all", "App.Server.handle_call/3"}]
    end
  end

  # #51: an excuse must stay true to its class's rules.
  describe "stale excuses" do
    alias Surfex.Log.Entry
    alias Surfex.Status.Report

    @coverage Profile.coverage!(@config)

    defp code_scan(id, kind, parent),
      do: %Scan{
        kind: :code,
        id: id,
        hash: "c1",
        location: %{file: "lib/s.ex", lines: {1, 2}},
        role: kind,
        within: parent
      }

    defp excuse(class, id),
      do:
        Entry.new!(
          at: "2026-09-28T10:00:00Z",
          op: :relate,
          type: :excuses,
          ends: [
            %{kind: :class, id: class, hash: hash(@config, class)},
            %{kind: :code, id: id, hash: "c1"}
          ]
        )

    defp status(code, entries, coverage \\ @coverage),
      do: Status.derive(Classes.records(@config) ++ code, entries, [], coverage: coverage)

    test "an item still matching its class's rule is not stale" do
      code = [code_scan("App.Server.handle_call/3", :function, "App.Server")]
      assert status(code, [excuse("plumbing", "App.Server.handle_call/3")]).stale == []
    end

    test "an item renamed out of its rule's pattern is stale, and fails" do
      # The excuse was confirmed for handle_call/3; the item is now called serve/3, and the
      # relation still names it (as a move would carry it).
      code = [code_scan("App.Server.serve/3", :function, "App.Server")]
      status = status(code, [excuse("plumbing", "App.Server.serve/3")])
      assert [%{class: "plumbing", code: "App.Server.serve/3", reason: :unmatched}] = status.stale
      assert Status.failing?(status)
    end

    test "a narrowed rule, another class's rule first, or an implementation make it stale" do
      code = [code_scan("App.Server.handle_info/2", :function, "App.Server")]
      entries = [excuse("plumbing", "App.Server.handle_info/2")]

      narrowed = put_in(@coverage, [:rules, Access.at(0), :name], ~r/^handle_call/)
      assert [%{reason: :unmatched}] = status(code, entries, narrowed).stale

      first = %{
        @coverage
        | rules: [
            %{class: "members", kinds: [:function], name: nil, parent_cited: false}
            | @coverage.rules
          ]
      }

      assert [%{reason: {:other_class, "members"}}] = status(code, entries, first).stale

      spec = %Scan{
        kind: :spec,
        id: "spec.md#S",
        hash: "s1",
        location: %{file: "spec.md", lines: {1, 1}},
        role: :section
      }

      implemented =
        Entry.new!(
          at: "2026-09-28T10:00:00Z",
          op: :relate,
          type: :implements,
          ends: [
            %{kind: :spec, id: "spec.md#S", hash: "s1"},
            %{kind: :code, id: "App.Server.handle_info/2", hash: "c1"}
          ]
        )

      assert [%{reason: :implemented}] = status([spec | code], [implemented | entries]).stale
    end

    test "all three reports show it; without the rules nothing is judged" do
      code = [code_scan("App.Server.serve/3", :function, "App.Server")]
      status = status(code, [excuse("plumbing", "App.Server.serve/3")])

      assert Report.text(status) =~
               "Stale (an excuse its class no longer covers):\n  class plumbing ↔ code App.Server.serve/3: no rule of its class matches it"

      {json, :ok, _} = status |> Report.json() |> :json.decode(:ok, %{null: nil})
      assert [%{"class" => "plumbing", "code" => "App.Server.serve/3"}] = json["stale"]
      assert status |> Report.golden() |> Surfex.Golden.render() =~ "## stale"

      assert Status.derive(Classes.records(@config) ++ code, [
               excuse("plumbing", "App.Server.serve/3")
             ]).stale == []
    end
  end
end
