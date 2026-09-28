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

  An entry is never edited or removed. A later entry for the same relation supersedes it
  and names it as a parent.

  The canonical line is JSON with keys in the order above. It is readable by anything
  (`jq`, other languages, an LLM), and parsing it never evaluates code.
  """

  @enforce_keys [:id, :at, :parents, :op, :type, :ends]
  defstruct [:id, :at, :commit, :op, :type, :by, :note, parents: [], ends: []]

  @ops [:relate, :retire]
  @types [:implements, :refines, :depends_on, :tests, :verifies, :excuses]
  @kinds [:spec, :code, :test, :config, :class]
  # "A depends on B" is not "B depends on A": these keep their ends in the order given.
  @directed [:depends_on, :refines, :tests, :verifies]

  @type end_ :: %{kind: atom, id: String.t(), hash: String.t() | nil}
  @type t :: %__MODULE__{
          id: String.t(),
          at: String.t(),
          commit: String.t() | nil,
          parents: [String.t()],
          op: :relate | :retire,
          type: atom,
          ends: [end_],
          by: String.t() | nil,
          note: String.t() | nil
        }

  @doc "The operations an entry may record."
  @spec ops() :: [atom]
  def ops, do: @ops

  @doc "The relation types."
  @spec types() :: [atom]
  def types, do: @types

  @doc "The directed types: their ends are from → to, in the order given."
  @spec directed() :: [atom]
  def directed, do: @directed

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
           note: fields[:note]
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

  @doc "The relation this entry is about: its type and its two ends' kinds and ids."
  @spec relation(t) :: {atom, {atom, String.t()}, {atom, String.t()}}
  def relation(%__MODULE__{type: type, ends: [a, b]}), do: {type, {a.kind, a.id}, {b.kind, b.id}}

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
             {:ok, type} <- atom(map["type"], @types, "type"),
             {:ok, ends} <- decode_ends(map["ends"]),
             {:ok, entry} <-
               build(
                 at: map["at"],
                 commit: map["commit"],
                 parents: map["parents"] || [],
                 op: op,
                 type: type,
                 ends: ends,
                 by: map["by"],
                 note: map["note"]
               ) do
          if entry.id == id,
            do: {:ok, entry},
            else:
              {:error, "entry #{String.slice(id, 0, 12)} does not match its content (edited?)"}
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

  defp sort_list(list) when is_list(list), do: Enum.sort(list)
  defp sort_list(other), do: other

  defp check(e) do
    cond do
      not (is_binary(e.at) and match?({:ok, _, 0}, DateTime.from_iso8601(e.at))) ->
        bad(:at, e.at)

      e.op not in @ops ->
        bad(:op, e.op)

      e.type not in @types ->
        bad(:type, e.type)

      length(e.ends) != 2 or Enum.any?(e.ends, &(&1.kind not in @kinds)) ->
        bad(:ends, e.ends)

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

  defp atom(text, allowed, field) do
    case Enum.find(allowed, &(Atom.to_string(&1) == text)) do
      nil -> {:error, "log entry field #{field} is invalid: #{inspect(text)}"}
      atom -> {:ok, atom}
    end
  end
end
