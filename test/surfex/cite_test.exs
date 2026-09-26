defmodule Surfex.CiteTest do
  use ExUnit.Case, async: true

  alias Surfex.{Cite, Item, Profile}

  @moduletag :tmp_dir

  defp item(name, opts \\ []),
    do: struct!(Item, [kind: :function, name: name, file: "lib/x.ex", hash: "00000000"] ++ opts)

  defp items do
    [
      item("app_send"),
      item("app_recv"),
      item("APP_MAX_OP", kind: :const),
      item("app_hdr", kind: :struct),
      item("offset", kind: :field, parent: "app_hdr"),
      item("offset", kind: :field, parent: "app_ack"),
      item("ack", kind: :field, parent: "app_hdr", type: "app_ack"),
      # A global and a member with one name: inside a section about app_hdr, the member wins.
      item("len", kind: :param),
      item("len", kind: :field, parent: "app_hdr"),
      # Two kinds, one key: what `:ambiguous` exists for.
      item("app_twice", kind: :function),
      item("app_twice", kind: :const)
    ]
  end

  defp profile(extra \\ []) do
    Profile.new!(
      [
        sources: ["spec/**/*.md", "models/*.ex"],
        exclude: ["spec/vendored/"],
        shape: ~r/^app_[a-z_]+$/,
        known_shape: ~r/^[A-Z_][A-Z0-9_]{3,}$/,
        normalise: [{~r/^struct\s+/, ""}, {~r/\(\)$/, ""}],
        known_external: %{"app_daemon" => "userspace, not vendored"},
        documented_absences: %{{"app_gone", "spec/01.md"} => "§2 reports its absence"}
      ] ++ extra
    )
  end

  defp write(root, path, text) do
    file = Path.join(root, path)
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, text)
  end

  defp cite(root, profile \\ profile()), do: Cite.citations(items(), profile, root)

  defp one(cites, span), do: Enum.filter(cites, &(&1.span == span))

  describe "statuses" do
    test "each of the five, from one spec", %{tmp_dir: root} do
      write(root, "spec/01.md", """
      # 1. Sending
      `app_send` resolves. `app_renamed` is unresolved. `app_twice` is ambiguous.
      `app_daemon` is external. `app_gone` is a documented absence. `:ok` is prose.
      """)

      cites = cite(root)
      assert [%{status: :resolved, items: ["app_send"]}] = one(cites, "app_send")
      assert [%{status: :unresolved, items: []}] = one(cites, "app_renamed")
      assert [%{status: :ambiguous, items: ["app_twice", "app_twice"]}] = one(cites, "app_twice")
      assert [%{status: :external}] = one(cites, "app_daemon")
      assert [%{status: :documented_absence}] = one(cites, "app_gone")
      assert one(cites, ":ok") == []
    end

    test "a documented absence is scoped to its file", %{tmp_dir: root} do
      write(root, "spec/02.md", "`app_gone`\n")
      assert [%{status: :unresolved}] = cite(root) |> one("app_gone")
    end
  end

  describe "sections" do
    test "credited to the nearest heading, or the preamble", %{tmp_dir: root} do
      write(root, "spec/01.md", "`app_send`\n# 1. Intro\n## 1.2 Detail\n`app_recv`\n")
      cites = cite(root)
      assert [%{section: "(preamble)", line: 1}] = one(cites, "app_send")
      assert [%{section: "1.2 Detail", line: 4}] = one(cites, "app_recv")
    end

    test "an .ex source is sectioned by defmodule", %{tmp_dir: root} do
      write(root, "models/m.ex", "defmodule Model.Send do\n  @moduledoc \"`app_send`\"\nend\n")
      assert [%{section: "Model.Send", file: "models/m.ex"}] = cite(root) |> one("app_send")
    end

    test "labels default to the file stem, or the first matching file_labels rewrite", %{
      tmp_dir: root
    } do
      write(root, "spec/01-intro.md", "# Intro\n`app_send`\n")
      cites = cite(root)
      assert Cite.by_item(cites, profile()) == %{"app_send" => ["01-intro — Intro"]}

      labelled = profile(file_labels: [{~r/^spec\/(\d+).*$/, "§\\1"}, {~r/.*/, "never"}])
      assert Cite.by_item(cites, labelled) == %{"app_send" => ["§01 — Intro"]}
    end

    test "a fence hides headings and spans from the line scan", %{tmp_dir: root} do
      write(root, "spec/01.md", "# Real\n```sh\n# not a heading `app_recv`\n```\n`app_send`\n")
      cites = cite(root)
      assert [%{section: "Real", line: 5}] = one(cites, "app_send")
      assert [%{section: "(code block)"}] = one(cites, "app_recv")
    end
  end

  describe "resolution" do
    test "normalisation applies before lookup", %{tmp_dir: root} do
      write(root, "spec/01.md", "`struct app_hdr` and `app_send()`\n")
      cites = cite(root)
      assert [%{status: :resolved, items: ["app_hdr"]}] = one(cites, "struct app_hdr")
      assert [%{status: :resolved, items: ["app_send"]}] = one(cites, "app_send()")
    end

    test "a member is reached by its key, never its bare name", %{tmp_dir: root} do
      write(root, "spec/01.md", "`app_hdr.offset` and `offset`\n")
      cites = cite(root)
      assert [%{status: :resolved, items: ["app_hdr.offset"]}] = one(cites, "app_hdr.offset")
      assert one(cites, "offset") == []
    end

    test "a subject section cites its items and scopes bare members", %{tmp_dir: root} do
      write(root, "spec/01.md", """
      # 3. The header
      `offset` and `len`
      ## 3.1 Detail
      `offset` again
      # 4. Other
      `offset` and `len`
      """)

      subjects = [%{file: "spec/01.md", heading: ~r/^3\. /, items: ["app_hdr", "app_gone_hdr"]}]
      cites = cite(root, profile(subjects: subjects))

      assert [
               %{status: :resolved, items: ["app_hdr"], line: 1},
               %{status: :unresolved, items: [], line: 1}
             ] = Enum.filter(cites, &(&1.span == "3. The header"))

      assert [%{line: 2, items: ["app_hdr.offset"]}, %{line: 4, items: ["app_hdr.offset"]}] =
               one(cites, "offset")

      assert [%{line: 2, items: ["app_hdr.len"]}, %{line: 6, items: ["len"]}] = one(cites, "len")
    end

    test "a subject applies only to its file", %{tmp_dir: root} do
      write(root, "spec/02.md", "# 3. The header\n`offset`\n")
      subjects = [%{file: ~r/01/, heading: ~r/^3\. /, items: ["app_hdr"]}]
      assert cite(root, profile(subjects: subjects)) == []
    end

    test "a member path walks through the member's type and cites every step", %{
      tmp_dir: root
    } do
      write(root, "spec/01.md", "`app_hdr.ack.offset`\n# 3. H\n`ack.offset` `ack.nope`\n")
      subjects = [%{file: "spec/01.md", heading: ~r/^3\. /, items: ["app_hdr"]}]
      cites = cite(root, profile(subjects: subjects))
      assert [%{items: ["app_hdr.ack", "app_ack.offset"]}] = one(cites, "app_hdr.ack.offset")
      assert [%{items: ["app_hdr.ack", "app_ack.offset"]}] = one(cites, "ack.offset")
      assert one(cites, "ack.nope") == []
    end

    test "inner tokens: shaped ones, and known-shape ones only if they resolve", %{tmp_dir: root} do
      write(root, "spec/01.md", "`ioctl(fd, APP_MAX_OP, NOT_OURS, int)` and `send(app_recv)`\n")
      cites = cite(root)
      assert [%{items: ["APP_MAX_OP"]}] = one(cites, "ioctl(fd, APP_MAX_OP, NOT_OURS, int)")
      assert [%{items: ["app_recv"]}] = one(cites, "send(app_recv)")
    end

    test "fenced blocks credit shaped tokens only, under (code block)", %{tmp_dir: root} do
      write(root, "spec/01.md", "```c\nint x = app_send(APP_MAX_OP);\napp_twice();\n```\n")
      cites = cite(root)
      assert [%{section: "(code block)", line: 1, status: :resolved}] = one(cites, "app_send")
      assert one(cites, "APP_MAX_OP") == []
      assert [%{status: :ambiguous}] = one(cites, "app_twice")
    end

    test "an alias cites its whole family; a shared key is still ambiguous", %{tmp_dir: root} do
      write(root, "spec/01.md", "`app_fam` and `app_twice`, and `x(app_fam)`\n")

      family = [
        item("f/1", parent: "mod", aliases: ["app_fam"]),
        item("f/2", parent: "mod", aliases: ["app_fam"])
      ]

      cites = Cite.citations(items() ++ family, profile(), root)
      assert [%{status: :resolved, items: ["mod.f/1", "mod.f/2"]}] = one(cites, "app_fam")
      assert [%{status: :resolved, items: ["mod.f/1", "mod.f/2"]}] = one(cites, "x(app_fam)")
      assert [%{status: :ambiguous}] = one(cites, "app_twice")
    end

    test "file targets are citable, :item_files adding every item's file", %{tmp_dir: root} do
      write(root, "spec/01.md", "`x.h` `lib/x.ex`\n")
      cites = cite(root, profile(file_targets: ["x.h", :item_files]))
      assert [%{status: :resolved, items: ["x.h"]}] = one(cites, "x.h")
      assert [%{status: :resolved, items: ["lib/x.ex"]}] = one(cites, "lib/x.ex")
    end

    test "table cells under a citing column are citations without backticks", %{tmp_dir: root} do
      write(root, "spec/01.md", """
      | Type | Value | Note |
      |---|---|---|
      | **APP_MAX_OP** | app_recv | `app_send` |
      | pad | 1 | x |
      | `app_recv` | 2 | y |

      | APP_MAX_OP | not a header row
      """)

      cites = cite(root, profile(table_columns: ["Type"]))
      assert [%{line: 3, status: :resolved, items: ["APP_MAX_OP"]}] = one(cites, "APP_MAX_OP")
      # Cited once, as a span; the Value column is not a citing column.
      assert [%{line: 5}] = one(cites, "app_recv")
      assert [%{line: 3}] = one(cites, "app_send")
    end
  end

  test "sources: globs, exclusions, sorted, de-duplicated", %{tmp_dir: root} do
    for p <- ~w(spec/b.md spec/a.md spec/vendored/c.md models/m.ex other/d.md),
        do: write(root, p, "")

    p = profile(sources: ["spec/**/*.md", "spec/*.md", "models/*.ex"])
    assert Cite.sources(p, root) == ~w(models/m.ex spec/a.md spec/b.md)
  end
end
