defmodule Surfex.Status.SpecShape do
  @moduledoc """
  The spec-shape warnings of a status (§11.12): what the spec scan saw that is probably a
  mistake in how the spec is written, though it reads as written. A warning never fails
  the status. Each kind is one entry of `kinds/0`, so the report, the JSON and any later
  kind share one listing:

    * `:list_key` — a marked table's row key that reads as a list (§11.2,
      `Surfex.Status.list_keys/1`);
    * `:path_heading` — a heading with no id among siblings the heading grammar numbered
      (§11.12), which is almost always a missed id.

  A kind read from the scan is a spec unit's `warnings` entry (`Surfex.Scan`); one read
  from the status, like `:list_key`, is made here from the status.
  """

  alias Surfex.{Scan, Status}

  @typedoc "One warning: its kind, where it is, the unit it is on, and what it says."
  @type t :: %{
          kind: atom,
          file: String.t(),
          line: pos_integer,
          unit: String.t(),
          message: String.t()
        }

  @kinds [
    list_key: "List-shaped keys (a table row's key that may name two things)",
    path_heading: "Path headings among numbered siblings (a heading with no id: a missed id?)"
  ]

  @doc "The kinds, in the order the report lists them, each with its listing's title."
  @spec kinds() :: [{atom, String.t()}]
  def kinds, do: @kinds

  @doc "Every spec-shape warning of the status, in file and line order."
  @spec warnings(Status.t()) :: [t]
  def warnings(status) do
    keys =
      for k <- Status.list_keys(status) do
        %{
          kind: :list_key,
          file: k.row.location.file,
          line: elem(k.row.location.lines, 0),
          unit: k.row.id,
          message: "row #{k.row.id} in table #{k.table}: its key holds #{inspect(k.separator)}"
        }
      end

    scanned =
      for {_key, %Scan{kind: :spec, warnings: [_ | _] = warnings} = scan} <- status.scans,
          w <- warnings,
          do: %{
            kind: w.kind,
            file: scan.location.file,
            line: w.line,
            unit: scan.id,
            message: w.message
          }

    Enum.sort_by(keys ++ scanned, &{&1.file, &1.line})
  end
end
