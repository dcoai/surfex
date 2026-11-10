defmodule Surfex.JSONTest do
  # #394, #395: a map's atom keys reached the encoder in the order the VM created the atoms,
  # so the same report could be written with its keys in another order after a compile.
  use ExUnit.Case, async: true
  @moduletag verifies: "json-key-order"

  alias Surfex.{Item, Scan, Suggest}
  alias Surfex.Status.Config
  alias Surfex.Scan.Markdown

  # The keys of every object, in the order the text writes them, depth first.
  defp key_orders(text) do
    decoders = %{
      object_start: fn _ -> [] end,
      object_push: fn k, v, acc -> [{k, v} | acc] end,
      object_finish: fn acc, old -> {{:object, Enum.reverse(acc)}, old} end
    }

    {value, :ok, ""} = :json.decode(text, :ok, decoders)
    orders(value)
  end

  defp orders({:object, pairs}),
    do: [Enum.map(pairs, &elem(&1, 0)) | Enum.flat_map(pairs, &orders(elem(&1, 1)))]

  defp orders(list) when is_list(list), do: Enum.flat_map(list, &orders/1)
  defp orders(_), do: []

  defp sorted?(text), do: Enum.all?(key_orders(text), &(&1 == Enum.sort(&1)))

  # Suggest.json/1 writes a list's maps with their keys as given, so it carries any key order
  # to the encoder: the cases below go through it, a writer, rather than the hidden encoder.
  test "keys are written sorted at every depth, whatever order the VM made the atoms in" do
    # Created z first: an atom-keyed map then holds z before a, and OTP wrote it so.
    n = System.unique_integer([:positive])
    z = String.to_atom("z_json_#{n}")
    a = String.to_atom("a_json_#{n}")

    text = Suggest.json(%{z => [%{z => 1, a => [%{z => nil, a => true}]}], a => []})

    assert text ==
             ~s({"a_json_#{n}":[],"z_json_#{n}":[{"a_json_#{n}":[{"a_json_#{n}":true,"z_json_#{n}":null}],"z_json_#{n}":1}]})

    assert sorted?(text)
  end

  test "atom, string and integer keys sort by name together; other values as OTP writes them" do
    assert Suggest.json(%{list: [%{:b => 1, "a" => 2, 3 => :null, c: [1.5, "x", false, :ok]}]}) ==
             ~s({"list":[{"3":null,"a":2,"b":1,"c":[1.5,"x",false,"ok"]}]})
  end

  @tag :tmp_dir
  test "suggest's JSON has every object's keys sorted", %{tmp_dir: root} do
    File.write!(Path.join(root, "spec.md"), "# Sending\n\n`Wren.send/3` sends.\n")
    items = [%Item{kind: :function, name: "send/3", parent: "Wren", file: "lib/w.ex", hash: "1"}]
    scans = Markdown.records(root, ["spec.md"]) ++ Scan.code(items)
    profile = Config.profile!([sources: ["spec.md"]], "Wren")

    text = profile |> Suggest.all(items, scans, [], root) |> Suggest.json()
    assert [top | _] = key_orders(text)
    assert "implements" in top
    assert sorted?(text)
  end

  # The recurrence guard rides here: a writer calling an encoder itself would bring the
  # VM's atom order back. Only Surfex.JSON does, and the relation log, whose lines keep
  # their canonical field order.
  @tag :tmp_dir
  test "the status report's JSON has every object's keys sorted, and no writer encodes past it",
       %{tmp_dir: root} do
    File.write!(Path.join(root, "spec.md"), "# Sending\n\n`Wren.send/3` sends.\n")
    items = [%Item{kind: :function, name: "send/3", parent: "Wren", file: "lib/w.ex", hash: "1"}]
    scans = Markdown.records(root, ["spec.md"]) ++ Scan.code(items)

    text = scans |> Surfex.Status.derive([]) |> Surfex.Status.Report.json()
    assert length(key_orders(text)) > 1
    assert sorted?(text)

    assert encoder_callers() == []
  end

  defp encoder_callers do
    allowed = ["lib/surfex/json.ex", "lib/surfex/log.ex", "lib/surfex/log/entry.ex"]

    for file <- Path.wildcard("lib/**/*.ex"),
        file not in allowed,
        {_, calls} =
          file
          |> File.read!()
          |> Code.string_to_quoted!()
          |> Macro.prewalk([], fn
            {{:., _, [:json, fun]}, _, _} = node, acc when fun != :decode ->
              {node, [{:json, fun} | acc]}

            {{:., _, [{:__aliases__, _, [:JSON]}, fun]}, _, _} = node, acc
            when fun in [:encode!, :encode, :encode_to_iodata!] ->
              {node, [{JSON, fun} | acc]}

            node, acc ->
              {node, acc}
          end),
        calls != [],
        do: {file, calls}
  end
end
