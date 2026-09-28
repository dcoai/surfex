defmodule Surfex.Record do
  @moduledoc """
  The recording commands' logic: from the scans and the log as they are, the entries to
  append. Pure; the Mix tasks read the scans and the log, and append what this returns.

  Every function returns `{:ok, [entry]}` or `{:error, reason}`. Nothing here edits or
  removes an entry. A new entry supersedes the old ones by naming them as parents.

  ## Ids

  An id is a scan id: `MyApp.Cart.add/2`, `spec.md#Carts/Adding items`. When the same id
  is scanned under two kinds, a `spec:` or `code:` prefix picks one. An id that isn't
  scanned is an error that names it, since relating what doesn't exist would be
  orphaned from the moment it was recorded.

  ## Who and when

  `meta` carries `:by`, `:commit` and optionally `:at` into every entry: who recorded it,
  HEAD at the time (context only), and when.
  """

  alias Surfex.{Scan, Status}
  alias Surfex.Log.Entry

  @type meta :: keyword

  @doc """
  Relates `from` and `to` as `type`, at their current hashes. For a directed type the
  order is from → to. Supersedes the relation's current tips, if any.
  """
  @spec relate([Scan.t()], [Entry.t()], String.t(), String.t(), atom, meta) ::
          {:ok, [Entry.t()]} | {:error, String.t()}
  def relate(scans, entries, from, to, type, meta) do
    with {:ok, a} <- find(scans, from),
         {:ok, b} <- find(scans, to),
         {:ok, entry} <-
           entry(:relate, type, [end_(a), end_(b)], parents(entries, type, a, b), meta) do
      {:ok, [entry]}
    end
  end

  @doc """
  For every **dangling** relation touching one of `ids`, a `relate` at the current hashes,
  superseding its tip. Only named ids: there is no confirming everything at once. An id
  with nothing dangling is an error, so a confirmation never quietly does nothing.
  """
  @spec confirm([Scan.t()], [Entry.t()], [String.t()], meta) ::
          {:ok, [Entry.t()]} | {:error, String.t()}
  def confirm(scans, entries, ids, meta) do
    status = Status.derive(scans, entries)

    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      with {:ok, scan} <- find(scans, id),
           key = {scan.kind, scan.id},
           dangling = for(r <- status.relations, r.state == :dangling, key in ends(r), do: r),
           :ok <- some(dangling, id),
           {:ok, confirmed} <- confirm_each(dangling, status, meta) do
        {:cont, {:ok, acc ++ confirmed}}
      else
        error -> {:halt, error}
      end
    end)
    |> dedupe()
  end

  @doc """
  Retires the relation of `type` between `from` and `to`: an entry naming every tip as a
  parent, with the ends as the tip recorded them. An end need not still be scanned, since
  retiring is how an orphaned relation is put to rest.
  """
  @spec retire([Scan.t()], [Entry.t()], String.t(), String.t(), atom, meta) ::
          {:ok, [Entry.t()]} | {:error, String.t()}
  def retire(scans, entries, from, to, type, meta) do
    with {:ok, tips} <- tips(scans, entries, from, to, type) do
      [tip | _] = tips

      with {:ok, entry} <- entry(:retire, type, tip.ends, Enum.map(tips, & &1.id), meta),
           do: {:ok, [entry]}
    end
  end

  @doc """
  Resolves a conflicted relation: the tip whose id starts with `pick` is recorded again
  with every tip as a parent. The relation is then judged by that entry. If the scans have
  moved since, it is dangling, and `confirm/4` is next.
  """
  @spec resolve([Scan.t()], [Entry.t()], String.t(), String.t(), atom, String.t(), meta) ::
          {:ok, [Entry.t()]} | {:error, String.t()}
  def resolve(scans, entries, from, to, type, pick, meta) do
    with {:ok, tips} <- tips(scans, entries, from, to, type),
         :ok <-
           if(length(tips) > 1,
             do: :ok,
             else: {:error, "the #{type} relation is not conflicted: nothing to resolve"}
           ),
         {:ok, chosen} <- choose(tips, pick),
         {:ok, entry} <-
           entry(chosen.op, type, chosen.ends, Enum.map(tips, & &1.id), meta, chosen.note) do
      {:ok, [entry]}
    end
  end

  @doc "Every entry with an end whose id is `id`, oldest first."
  @spec history([Entry.t()], String.t()) :: [Entry.t()]
  def history(entries, id) do
    bare = strip_kind(id)

    entries
    |> Enum.filter(fn e -> Enum.any?(e.ends, &(&1.id == bare)) end)
    |> Enum.sort_by(&{&1.at, &1.id})
  end

  # ── Pieces ──────────────────────────────────────────────────────────────

  defp confirm_each(dangling, status, meta) do
    Enum.reduce_while(dangling, {:ok, []}, fn r, {:ok, acc} ->
      [tip] = r.tips

      ends = Enum.map(tip.ends, fn e -> end_(Map.fetch!(status.scans, {e.kind, e.id})) end)

      case entry(:relate, r.type, ends, [tip.id], meta) do
        {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
        error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, list} -> {:ok, Enum.reverse(list)}
      error -> error
    end)
  end

  defp dedupe({:ok, entries}), do: {:ok, Enum.uniq_by(entries, &Entry.relation/1)}
  defp dedupe(error), do: error

  defp some([], id), do: {:error, "nothing dangling touches #{id}: nothing to confirm"}
  defp some(_list, _id), do: :ok

  defp ends(%{relation: {_type, a, b}}), do: [a, b]

  defp tips(scans, entries, from, to, type) do
    with {:ok, a} <- find_or_recorded(scans, entries, from),
         {:ok, b} <- find_or_recorded(scans, entries, to) do
      case Status.tips(entries, Entry.relation(type, a, b)) do
        [] -> {:error, "no #{type} relation between #{from} and #{to} in the log"}
        tips -> {:ok, tips}
      end
    end
  end

  # An end for a relation that may already be orphaned: the scan if there is one, else the
  # last recorded form of that id.
  defp find_or_recorded(scans, entries, id) do
    case find(scans, id) do
      {:ok, scan} ->
        {:ok, end_(scan)}

      {:error, _} = error ->
        bare = strip_kind(id)

        case entries
             |> Enum.flat_map(& &1.ends)
             |> Enum.filter(&(&1.id == bare))
             |> List.last() do
          nil -> error
          recorded -> {:ok, recorded}
        end
    end
  end

  defp choose(tips, pick) do
    case Enum.filter(tips, &String.starts_with?(&1.id, pick)) do
      [one] ->
        {:ok, one}

      [] ->
        {:error,
         "no tip's id starts with #{pick}; the tips are #{Enum.map_join(tips, ", ", &String.slice(&1.id, 0, 12))}"}

      _ ->
        {:error, "#{pick} names more than one tip; give more of the id"}
    end
  end

  defp parents(entries, type, a, b) do
    entries |> Status.tips(Entry.relation(type, end_(a), end_(b))) |> Enum.map(& &1.id)
  end

  defp entry(op, type, ends, parents, meta, note \\ nil) do
    Entry.build(
      at:
        Keyword.get_lazy(meta, :at, fn ->
          DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
        end),
      commit: meta[:commit],
      by: meta[:by],
      note: Keyword.get(meta, :note, note),
      op: op,
      type: type,
      parents: parents,
      ends: ends
    )
  end

  defp end_(%Scan{kind: kind, id: id, hash: hash}), do: %{kind: kind, id: id, hash: hash}

  # ── Ids ─────────────────────────────────────────────────────────────────

  defp find(scans, id) do
    {kind, bare} = split_kind(id)

    case Enum.filter(scans, &(&1.id == bare and (kind == nil or &1.kind == kind))) do
      [scan] -> {:ok, scan}
      [] -> {:error, "#{id} is not scanned: no spec section or code item has that id"}
      _ -> {:error, "#{id} is scanned as more than one kind; prefix it with spec: or code:"}
    end
  end

  defp split_kind("spec:" <> rest), do: {:spec, rest}
  defp split_kind("code:" <> rest), do: {:code, rest}
  defp split_kind(id), do: {nil, id}

  defp strip_kind(id), do: id |> split_kind() |> elem(1)
end
