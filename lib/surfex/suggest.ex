defmodule Surfex.Suggest do
  @moduledoc """
  Candidate relations from what the spec already says: every place a spec section names a
  code item is a candidate `implements` relation between the two.

  It reads the spec's citations as the trace does (`Surfex.Cite`, with the project's
  profile). For each **resolved** citation, the candidate is the pair *(the spec section
  containing the citation's line, each code item the citation names)*. A family (`Mod.fun`)
  names every member. Leaving things out:

    * a pair already related, in any state, including retired: suggesting it again would
      overrule a decision already on record
    * a citation inside a fenced code block, which has no line to place it in a section
    * a named item that is not a code scan (a file target, say)

  This is also how a project adopts the relation log: `mix surfex.log --init`, then
  `mix surfex.suggest --accept`.
  """

  alias Surfex.{Record, Scan, Trace}
  alias Surfex.Log.Entry

  @type candidate :: %{spec: Scan.t(), code: Scan.t(), cited_at: {String.t(), pos_integer}}

  @doc """
  The candidates, sorted by section then item, one per pair: the first citation that
  proposes a pair is where it was cited.
  """
  @spec candidates(Trace.t(), [Surfex.Item.t()], [Scan.t()], [Entry.t()], String.t()) :: [
          candidate
        ]
  def candidates(trace, items, scans, entries, root) do
    citations = Trace.analyse(trace, items, root).citations
    sections = Enum.filter(scans, &(&1.kind == :spec))
    code = for s <- scans, s.kind == :code, into: %{}, do: {s.id, s}
    related = MapSet.new(entries, &Entry.relation/1)

    for %{status: :resolved} = c <- citations,
        c.section != "(code block)",
        section = section_at(sections, c.file, c.line),
        section != nil,
        key <- c.items,
        item = Map.get(code, key),
        item != nil,
        not MapSet.member?(related, Entry.relation(:implements, section, item)) do
      %{spec: section, code: item, cited_at: {c.file, c.line}}
    end
    |> Enum.uniq_by(&{&1.spec.id, &1.code.id})
    |> Enum.sort_by(&{&1.spec.id, &1.code.id})
  end

  @doc """
  One `relate` entry per candidate, at the current hashes. It only ever creates relations
  that don't exist; it never confirms a dangling one.
  """
  @spec accept([candidate], [Scan.t()], [Entry.t()], keyword) ::
          {:ok, [Entry.t()]} | {:error, String.t()}
  def accept(candidates, scans, entries, meta) do
    Enum.reduce_while(candidates, {:ok, []}, fn c, {:ok, acc} ->
      case Record.relate(
             scans,
             entries ++ acc,
             "spec:" <> c.spec.id,
             "code:" <> c.code.id,
             :implements,
             meta
           ) do
        {:ok, recorded} -> {:cont, {:ok, acc ++ recorded}}
        error -> {:halt, error}
      end
    end)
  end

  # The section whose lines contain `line` in `file`: sections don't overlap, since each
  # stops at the next heading of any level.
  defp section_at(sections, file, line) do
    Enum.find(sections, fn %Scan{location: %{file: f, lines: {first, last}}} ->
      f == file and line >= first and line <= last
    end)
  end
end
