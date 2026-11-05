defmodule Surfex.LibraryFilesTest do
  # #293, #357: a project may load Surfex.Golden and Surfex.SourceScan from source, with no
  # Mix project. "Unchanged API" didn't tell it that 0.10's Golden needed a new file. The
  # guide lists each module's files; these tests compute the lists rather than trust them,
  # so a new reference fails here until the guide says so.
  use ExUnit.Case, async: true
  @moduletag verifies: "library-file-sets"

  @guide "guides/using-surfex-as-a-library.md"

  @golden_calls [
    {"natural_key/1", ~s|Surfex.Golden.natural_key("a10")|},
    {"render/1",
     ~s|Surfex.Golden.render(%{name: "X.md", purpose: "p", task: "t", gate: "g", hardness: :hard, | <>
       ~s|columns: ["F", "V"], rows: [%{"F" => {:code, "a`b"}, "V" => {:version, "abcd1234"}}]})|},
    {"stat/2", ~s|Surfex.Golden.stat("3 rows", [{"new", 1}])|},
    {"stat_line/2", ~s|Surfex.Golden.stat_line("3 rows", [{"new", 1}])|}
  ]

  @quoted ~s|Code.string_to_quoted!("defmodule M do\\n  def f(x), do: g(x)\\n  defp g(x), do: x\\nend")|

  @scan_calls [
    {"definition_hash/1", ~s|Surfex.SourceScan.definition_hash("def f, do: 1")|},
    {"defmodules/1", "Surfex.SourceScan.defmodules(#{@quoted})"},
    {"defs/1", "Surfex.SourceScan.defs(#{@quoted})"},
    {"hidden_module?/1", "Surfex.SourceScan.hidden_module?(#{@quoted})"},
    {"lib_sources/1", ~s|Surfex.SourceScan.lib_sources("lib")|},
    {"line_range/1", "Surfex.SourceScan.line_range(#{@quoted})"},
    {"module_hash/1", "Surfex.SourceScan.module_hash(#{@quoted})"},
    {"project_root/2", ~s|Surfex.SourceScan.project_root("lib/surfex", "mix.exs")|},
    {"types/1", "Surfex.SourceScan.types(#{@quoted})"}
  ]

  # The guide's table: `Module` | `file`, `file`.
  defp listed do
    for line <- @guide |> File.read!() |> String.split("\n"),
        [_, module, files] <- [Regex.run(~r/^\| `(Surfex\.\w+)` \| (.+) \|$/, line)],
        into: %{},
        do: {module, for([_, f] <- Regex.scan(~r/`([^`]+)`/, files), do: f)}
  end

  # The files `entry` needs under `root`: its own, and those of every module its code names,
  # followed through theirs. Read from source, so a string or a comment naming a module
  # counts for nothing.
  defp file_set(root, entry) do
    files =
      for path <- Path.wildcard(Path.join(root, "lib/**/*.ex")), into: %{} do
        quoted = path |> File.read!() |> Code.string_to_quoted!()
        {Path.relative_to(path, root), quoted}
      end

    owners =
      for {file, quoted} <- files, module <- defined(quoted), into: %{}, do: {module, file}

    needs =
      for {file, quoted} <- files, into: %{} do
        {file, quoted |> named() |> Enum.flat_map(&List.wrap(owners[&1])) |> Enum.uniq()}
      end

    reach([entry], needs, []) |> Enum.sort()
  end

  defp reach([], _needs, seen), do: seen

  defp reach([file | rest], needs, seen) do
    if file in seen,
      do: reach(rest, needs, seen),
      else: reach(needs[file] ++ rest, needs, [file | seen])
  end

  defp defined(quoted) do
    {_, found} =
      Macro.prewalk(quoted, [], fn
        {:defmodule, _, [{:__aliases__, _, parts} | _]} = node, acc ->
          {node, [Module.concat(parts) | acc]}

        node, acc ->
          {node, acc}
      end)

    found
  end

  # The modules a file's code names, with its aliases read: `alias A.B` and
  # `alias A.{B, C}` make `B.f()` a call to `A.B`.
  defp named(quoted) do
    {_, {aliases, names}} =
      Macro.prewalk(quoted, {%{}, []}, fn
        {:alias, _, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, subs} | _]} = node, {as, ns} ->
          as =
            for {:__aliases__, _, sub} <- subs,
                into: as,
                do: {List.last(sub), base ++ sub}

          {node, {as, ns}}

        {:alias, _, [{:__aliases__, _, parts} | _]} = node, {as, ns} ->
          {node, {Map.put(as, List.last(parts), parts), ns}}

        {:__aliases__, _, parts} = node, {as, ns} ->
          {node, {as, [parts | ns]}}

        node, acc ->
          {node, acc}
      end)

    for [head | tail] = parts <- names,
        Enum.all?(parts, &is_atom/1),
        do: Module.concat(Map.get(aliases, head, [head]) ++ tail)
  end

  defp documented(module) do
    {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(module)
    for {{:function, name, arity}, _, _, doc, _} <- docs, doc != :hidden, do: "#{name}/#{arity}"
  end

  # A new OS process with only `files` loaded: no Mix, and none of this project's code.
  defp fresh_elixir(files, calls) do
    required = Enum.flat_map(files, &["-r", &1])
    script = Enum.map_join(calls, "\n", fn {_, call} -> "_ = #{call}" end) <> "\nIO.write(:ok)"
    System.cmd("elixir", required ++ ["-e", script], stderr_to_stdout: true)
  end

  @tag verifies: ["library-file-sets", "library-files"]
  test "the guide lists each library module's files, as its code computes them" do
    assert Map.new(listed(), fn {module, files} -> {module, Enum.sort(files)} end) == %{
             "Surfex.Golden" => file_set(".", "lib/surfex/golden.ex"),
             "Surfex.SourceScan" => file_set(".", "lib/surfex/source_scan.ex")
           }
  end

  @tag :tmp_dir
  test "a module's file set follows what its code names, and nothing else", %{tmp_dir: root} do
    write = fn path, source ->
      full = Path.join(root, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, source)
    end

    write.("lib/a.ex", "defmodule A do\n  alias B.C\n  def f, do: C.g()\nend\n")
    write.("lib/b/c.ex", "defmodule B.C do\n  alias B.{E}\n  def g, do: E.h() && D.h()\nend\n")
    write.("lib/d.ex", "defmodule D do\n  def h, do: A.f()\nend\n")

    write.(
      "lib/b/e.ex",
      "defmodule B.E do\n  @moduledoc \"Unused.i/0 isn't called.\"\n  def h, do: 1\nend\n"
    )

    write.("lib/unused.ex", "defmodule Unused do\n  def i, do: 1\nend\n")

    assert file_set(root, "lib/a.ex") == ["lib/a.ex", "lib/b/c.ex", "lib/b/e.ex", "lib/d.ex"]
  end

  test "these calls are every documented function of the library modules" do
    assert Enum.sort(documented(Surfex.Golden)) == Enum.map(@golden_calls, &elem(&1, 0))
    assert Enum.sort(documented(Surfex.SourceScan)) == Enum.map(@scan_calls, &elem(&1, 0))
  end

  test "with exactly the listed files loaded and no Mix project, every documented function runs" do
    sets = listed()

    assert {"ok", 0} = fresh_elixir(sets["Surfex.Golden"], @golden_calls)

    # Its two files call each other, so one compile warning prints in either order (the guide
    # says so); what matters is that it ran to the end.
    assert {output, 0} = fresh_elixir(sets["Surfex.SourceScan"], @scan_calls)
    assert String.ends_with?(output, "ok")
  end

  test "without the rest of its set, a module's own file isn't enough" do
    assert {output, status} = fresh_elixir(["lib/surfex/golden.ex"], @golden_calls)
    assert status != 0
    assert output =~ "Surfex.Golden.Span"

    assert {output, status} = fresh_elixir(["lib/surfex/source_scan.ex"], @scan_calls)
    assert status != 0
    assert output =~ "Surfex.SourceScan.Closure"
  end
end
