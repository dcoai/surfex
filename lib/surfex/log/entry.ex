defmodule Surfex.Log.Entry do
  @moduledoc """
  One entry of the relation log: a recorded judgement that two things relate, at two
  versions.

  | Field | Meaning |
  |---|---|
  | `id` | SHA-256 of the entry's canonical line without `id`: stable, and changed by any edit |
  | `at` | when it was recorded, UTC ISO 8601: orders the history |
  | `commit` | HEAD when it was recorded: context only, and may be squashed away |
  | `parents` | the entry ids it follows for the same relation; two means it resolves a fork |
  | `op` | `:relate` or `:retire` |
  | `type` | `:implements`, `:refines`, `:depends_on`, `:tests`, `:verifies` (a test verifies a spec unit) or `:excuses` |
  | `ends` | two `%{kind, id, hash}`: in order, from → to, for a directed type; sorted for an undirected one, so A↔B and B↔A are one relation. A `nil` hash (JSON `null`) is a **planned** end: an id that didn't exist when the relation was recorded. At most one end is planned. |
  | `by` | who recorded it |
  | `note` | why, optionally |
  | `basis` | how it validates the relation: `:evidence`, `:review`, `:judgement`, `:baseline` or `:proposed`; absent when it validates nothing |

  Which ends and bases each type and op may have is the grammar of spec §12.1, enforced by
  `build/1` and so by `decode/1`.

  An entry is never edited or removed. A later entry for the same relation supersedes it
  and names it as a parent.

  The canonical line is JSON with keys in the order above. It is readable by anything
  (`jq`, other languages, an LLM), and parsing it never evaluates code.
  """

  @enforce_keys [:id, :at, :parents, :op, :type, :ends]
  defstruct [:id, :at, :commit, :op, :type, :by, :note, :basis, parents: [], ends: []]

  @ops [:relate, :retire, :mark, :observe]
  @bases [:evidence, :review, :judgement, :baseline, :proposed]
  @types [:implements, :refines, :depends_on, :tests, :verifies, :excuses]
  # A mark is a statement about one spec unit, not a relation (§12.1).
  @mark_types [:needs_update]
  # An observation is a fact about one test version (§12.1, §17), not a relation.
  @observation_types [:red_green, :baseline]
  @kinds [:spec, :code, :test, :class]
  # The grammar (§12.1): each type's ends, in order (sorted for an undirected type), and
  # the bases it may carry. `nil` is no basis; for implements, verifies and excuses it is
  # legacy, admitted for entries written before bases existed.
  @grammar %{
    implements: {[:code, :spec], [nil, :proposed, :evidence, :review, :judgement, :baseline]},
    verifies: {[:test, :spec], [nil, :proposed, :evidence, :review, :judgement, :baseline]},
    tests: {[:test, :code], [nil, :evidence, :judgement, :baseline]},
    refines: {[:spec, :spec], [nil, :judgement]},
    depends_on: {[:code, :code], [nil, :judgement]},
    excuses: {[:class, :code], [nil, :proposed, :judgement]},
    needs_update: {[:spec], [nil]},
    red_green: {[:test], [:evidence]},
    baseline: {[:test], [:baseline]}
  }
  # "A depends on B" is not "B depends on A": these keep their ends in the order given.
  @directed [:depends_on, :refines, :tests, :verifies]

  @type end_ :: %{kind: atom, id: String.t(), hash: String.t() | nil}
  @type t :: %__MODULE__{
          id: String.t(),
          at: String.t(),
          commit: String.t() | nil,
          parents: [String.t()],
          op: :relate | :retire | :mark | :observe,
          type: atom,
          ends: [end_],
          by: String.t() | nil,
          note: String.t() | nil,
          basis: :evidence | :review | :judgement | :baseline | :proposed | nil
        }

  @doc "The operations an entry may record."
  @spec ops() :: [atom]
  def ops, do: @ops

  @doc "The relation types."
  @spec types() :: [atom]
  def types, do: @types

  @doc "The mark types: statements about one spec unit, not relations."
  @spec mark_types() :: [atom]
  def mark_types, do: @mark_types

  @doc "The observation types: facts about one test version, not relations."
  @spec observation_types() :: [atom]
  def observation_types, do: @observation_types

  @doc "Whether an entry is a relation's, not a mark's or an observation's."
  @spec relation?(t) :: boolean
  def relation?(%__MODULE__{type: type}), do: type in @types

  @doc "Whether an entry is a mark's (the mark, or the retire that withdraws it)."
  @spec mark?(t) :: boolean
  def mark?(%__MODULE__{type: type}), do: type in @mark_types

  @doc "The directed types: their ends are from → to, in the order given."
  @spec directed() :: [atom]
  def directed, do: @directed

  @doc "The bases an entry may record for validating its relation."
  @spec bases() :: [atom]
  def bases, do: @bases

  @doc "The kinds an end may be."
  @spec kinds() :: [atom]
  def kinds, do: @kinds

  @doc """
  An entry from its fields, with its ends sorted and its `id` computed, or the reason it
  can't be one. `at` defaults to now.
  """
  @spec build(keyword | map) :: {:ok, t} | {:error, String.t()}
  def build(fields) do
    fields = Map.new(fields)

    at =
      Map.get_lazy(fields, :at, fn ->
        DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      end)

    with {:ok, ends} <- ends(Map.get(fields, :ends, [])),
         entry = %__MODULE__{
           id: "",
           at: at,
           commit: fields[:commit],
           parents: fields |> Map.get(:parents, []) |> sort_list(),
           op: fields[:op],
           type: fields[:type],
           ends: orient(fields[:type], ends),
           by: fields[:by],
           note: fields[:note],
           basis: fields[:basis]
         },
         :ok <- check(entry) do
      {:ok, %{entry | id: id(entry)}}
    end
  end

  @doc "`build/1`, raising `ArgumentError` with the reason."
  @spec new!(keyword | map) :: t
  def new!(fields) do
    case build(fields) do
      {:ok, entry} -> entry
      {:error, why} -> raise ArgumentError, why
    end
  end

  @doc """
  The relation this entry is about: its type and its two ends' kinds and ids. A mark's is
  its type and its one end.
  """
  @spec relation(t) ::
          {atom, {atom, String.t()}, {atom, String.t()}} | {atom, {atom, String.t()}}
  def relation(%__MODULE__{type: type, ends: [a, b]}), do: {type, {a.kind, a.id}, {b.kind, b.id}}
  def relation(%__MODULE__{type: type, ends: [a]}), do: {type, {a.kind, a.id}}

  @doc """
  The relation of `type` between two ends (`%{kind, id}` or more), oriented as an entry's
  would be: in order for a directed type, sorted otherwise.
  """
  @spec relation(atom, map, map) :: {atom, {atom, String.t()}, {atom, String.t()}}
  def relation(type, a, b) do
    [a, b] = orient(type, [a, b])
    {type, {a.kind, a.id}, {b.kind, b.id}}
  end

  @doc "The canonical line, without a trailing newline."
  @spec encode(t) :: String.t()
  def encode(%__MODULE__{} = entry), do: canonical(entry, true)

  @doc """
  An entry from a canonical line, or why it isn't one: a missing or unknown field, or an
  id that no longer matches the content (the line was edited). A line that is not JSON at
  all raises: the file is corrupt, and that must not be quiet.
  """
  @spec decode(String.t()) :: {:ok, t} | {:error, String.t()}
  def decode(line) do
    case json(line) do
      %{"id" => id} = map when is_binary(id) ->
        with {:ok, op} <- atom(map["op"], @ops, "op"),
             {:ok, type} <- atom(map["type"], @types ++ @mark_types ++ @observation_types, "type"),
             {:ok, ends} <- decode_ends(map["ends"]),
             {:ok, basis} <- basis(map["basis"]),
             {:ok, entry} <-
               build(
                 at: map["at"],
                 commit: map["commit"],
                 parents: map["parents"] || [],
                 op: op,
                 type: type,
                 ends: ends,
                 by: map["by"],
                 note: map["note"],
                 basis: basis
               ) do
          if entry.id == id,
            do: {:ok, entry},
            else:
              {:error, "entry #{String.slice(id, 0, 12)} does not match its content (edited?)"}
        else
          {:error, why} -> {:error, "entry #{String.slice(id, 0, 12)}: #{why}"}
        end

      _ ->
        {:error, "not a log entry: #{String.slice(line, 0, 80)}"}
    end
  end

  @doc """
  One JSON value from a line, with `null` as `nil` (OTP's `:json` decodes it as the atom
  `:null` by default). Raises on text that is not JSON.
  """
  @spec json(String.t()) :: term
  def json(line) do
    {value, :ok, rest} = :json.decode(line, :ok, %{null: nil})

    if String.trim(rest) == "",
      do: value,
      else: raise(ArgumentError, "trailing text after JSON: #{String.slice(rest, 0, 40)}")
  end

  @doc "`decode/1`, raising `ArgumentError` with the reason."
  @spec decode!(String.t()) :: t
  def decode!(line) do
    case decode(line) do
      {:ok, entry} -> entry
      {:error, why} -> raise ArgumentError, why
    end
  end

  # ── Canonical form ──────────────────────────────────────────────────────

  defp id(entry),
    do: :crypto.hash(:sha256, canonical(entry, false)) |> Base.encode16(case: :lower)

  defp canonical(entry, with_id?) do
    fields = [
      {"at", entry.at},
      {"commit", entry.commit},
      {"parents", entry.parents},
      {"op", Atom.to_string(entry.op)},
      {"type", Atom.to_string(entry.type)},
      {"ends",
       Enum.map(
         entry.ends,
         &{:object, [{"kind", Atom.to_string(&1.kind)}, {"id", &1.id}, {"hash", &1.hash}]}
       )},
      {"by", entry.by},
      {"note", entry.note}
    ]

    # Written only when set, so an entry recorded before bases existed keeps its line and id.
    fields = if entry.basis, do: fields ++ [{"basis", Atom.to_string(entry.basis)}], else: fields
    fields = if with_id?, do: [{"id", entry.id} | fields], else: fields
    IO.iodata_to_binary(value({:object, fields}))
  end

  # JSON with keys in the given order: `:json.encode/1` makes no promise about a map's.
  defp value({:object, pairs}),
    do: [
      "{",
      pairs
      |> Enum.map(fn {k, v} -> [:json.encode(k), ":", value(v)] end)
      |> Enum.intersperse(","),
      "}"
    ]

  defp value(list) when is_list(list),
    do: ["[", list |> Enum.map(&value/1) |> Enum.intersperse(","), "]"]

  defp value(nil), do: "null"
  defp value(v), do: :json.encode(v)

  # ── Validation ──────────────────────────────────────────────────────────

  defp ends(list) when is_list(list) do
    if Enum.all?(list, &end?/1),
      do: {:ok, Enum.map(list, &Map.take(&1, [:kind, :id, :hash]))},
      else: bad(:ends, list)
  end

  defp ends(other), do: bad(:ends, other)

  defp end?(%{kind: kind, id: id, hash: hash}),
    do: is_atom(kind) and is_binary(id) and (is_binary(hash) or is_nil(hash))

  defp end?(_), do: false

  defp decode_ends(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn
      %{"kind" => kind, "id" => id, "hash" => hash}, {:ok, acc} ->
        case atom(kind, @kinds, "kind") do
          {:ok, kind} -> {:cont, {:ok, acc ++ [%{kind: kind, id: id, hash: hash}]}}
          error -> {:halt, error}
        end

      other, _acc ->
        {:halt, bad(:ends, other)}
    end)
  end

  defp decode_ends(other), do: bad(:ends, other)

  defp orient(type, ends) when type in @directed, do: ends
  defp orient(_type, ends), do: Enum.sort_by(ends, &{&1.kind, &1.id})

  defp shape(type) do
    case elem(@grammar[type], 0) do
      [one] -> "one #{one}"
      [a, b] -> "#{a} #{if type in @directed, do: "→", else: "↔"} #{b}"
    end
  end

  defp kinds(ends), do: Enum.map_join(ends, ", ", &to_string(&1.kind))

  defp basis_name(nil), do: "no basis"
  defp basis_name(basis), do: "basis #{basis}"

  defp sort_list(list) when is_list(list), do: Enum.sort(list)
  defp sort_list(other), do: other

  defp check(e) do
    cond do
      not (is_binary(e.at) and match?({:ok, _, 0}, DateTime.from_iso8601(e.at))) ->
        bad(:at, e.at)

      e.op not in @ops ->
        bad(:op, e.op)

      e.type not in (@types ++ @mark_types ++ @observation_types) ->
        bad(:type, e.type)

      # A mark is made by a mark op and withdrawn by a retire; relations never use `mark`.
      (e.op == :mark and e.type not in @mark_types) or (e.op == :relate and e.type in @mark_types) ->
        bad(:type, e.type)

      # An observation is made only by an observe op, and an observe op makes only one.
      e.op == :observe != e.type in @observation_types ->
        bad(:type, e.type)

      not (is_nil(e.basis) or e.basis in @bases) ->
        bad(:basis, e.basis)

      Enum.map(e.ends, & &1.kind) != elem(@grammar[e.type], 0) ->
        {:error, "#{e.type} ends must be #{shape(e.type)}, got #{kinds(e.ends)}"}

      # A mark and an observation are of a version: their one end always has a hash.
      e.type not in @types and Enum.any?(e.ends, &is_nil(&1.hash)) ->
        bad(:ends, e.ends)

      e.op == :retire and e.basis != nil ->
        {:error, "a retire carries no basis, got #{e.basis}"}

      e.op == :mark and e.basis != nil ->
        {:error, "a mark carries no basis, got #{e.basis}"}

      e.basis not in elem(@grammar[e.type], 1) ->
        {:error,
         "#{e.type} can't carry #{basis_name(e.basis)} (allowed: " <>
           Enum.map_join(elem(@grammar[e.type], 1), ", ", &basis_name/1) <> ")"}

      # Planning a relation between two things neither of which exists records nothing.
      Enum.all?(e.ends, &is_nil(&1.hash)) ->
        bad(:ends, e.ends)

      not (is_list(e.parents) and Enum.all?(e.parents, &is_binary/1)) ->
        bad(:parents, e.parents)

      not Enum.all?([e.commit, e.by, e.note], &(is_nil(&1) or is_binary(&1))) ->
        bad(:commit_by_note, {e.commit, e.by, e.note})

      true ->
        :ok
    end
  end

  defp bad(field, value),
    do: {:error, "log entry field #{inspect(field)} is invalid: #{inspect(value)}"}

  defp basis(nil), do: {:ok, nil}
  defp basis(text), do: atom(text, @bases, "basis")

  defp atom(text, allowed, field) do
    case Enum.find(allowed, &(Atom.to_string(&1) == text)) do
      nil -> {:error, "log entry field #{field} is invalid: #{inspect(text)}"}
      atom -> {:ok, atom}
    end
  end
end
