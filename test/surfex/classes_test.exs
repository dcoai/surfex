defmodule Surfex.ClassesTest do
  use ExUnit.Case, async: true

  alias Surfex.{Item, Profile, Scan, Status, Suggest, Trace}
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
      trace = Trace.new!([namespace: "App", sources: ["spec.md"]] ++ config)
      scans = Markdown.records(root, ["spec.md"]) ++ Scan.code(@items) ++ Classes.records(config)
      {Suggest.all(trace, @items, scans, entries, root), scans}
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

  # The v0.2 trace's verdicts, expressed in the relation log: the reference fixture's
  # classes excuse exactly the items its trace golden prints as excused.
  test "the reference fixture's excusals match its trace" do
    fixture = Path.expand("../fixtures/reference_trace", __DIR__)
    {items, _} = Code.eval_file(Path.join(fixture, "items.exs"))
    items = Enum.map(items, &struct!(Item, &1))
    {config, _} = Code.eval_file(Path.join(fixture, "trace.exs"))
    trace = Trace.new!(config)
    root = Path.join(fixture, "sources")

    scans =
      Markdown.records(root, ["spec/**/*.md", "notes/**/*.md"]) ++
        Scan.code(items) ++ Classes.records(config)

    suggested = Suggest.all(trace, items, scans, [], root) |> excuses()

    traced =
      for {item, {:expected, class}} <- Trace.analyse(trace, items, root).verdicts,
          do: {class, Item.key(item)}

    assert suggested == Enum.sort(traced)
    assert length(suggested) == 5
  end
end
