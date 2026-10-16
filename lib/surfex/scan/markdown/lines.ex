defmodule Surfex.Scan.Markdown.Lines do
  @moduledoc false
  # What every part of the markdown scanner reads a line by, and how it fails.

  alias Surfex.Scan.Markdown.Fence

  @id "[A-Za-z0-9][A-Za-z0-9._:-]*"
  @hint ~r/^test(?:\s+|:)(\S+)$/
  @own_marker ~r/^\s*<!--\s*\/?surfex\b.*-->\s*$/

  # What a block or hint opened now sits in.
  def within(%{rule: %{id: id}}), do: {:rule, id}
  def within(%{block: %{id: id}}), do: {:block, id}
  def within(%{cur: %{n: n}}), do: {:section, n}

  def unit(open, role, last),
    do: %{
      role: role,
      id: open.id,
      first: open.first,
      last: last,
      body: Enum.reverse(open.body),
      within: open.within,
      deferred: Map.get(open, :deferred)
    }

  # A section's last line is its last non-blank line, so trailing blank lines before the
  # next heading are not counted as its content.
  def extend(cur, line, no), do: if(String.trim(line) == "", do: cur, else: %{cur | last: no})

  def hint_id(line) do
    with info when is_binary(info) <- Fence.info(line),
         [id] <- Regex.run(@hint, info, capture: :all_but_first),
         do: id,
         else: (_ -> nil)
  end

  # An id as written, `{st, id}`: one that breaks the id rule is a scan error, and the scan
  # goes on with it as written (it fails at the end).
  def checked_id(st, no, id, what) do
    if Regex.match?(~r/^#{@id}$/, id),
      do: {st, id},
      else:
        {fail(
           st,
           no,
           "#{what} id #{inspect(id)} must be letters, digits and . _ - :, starting with a letter or digit"
         ), id}
  end

  def heading(line) do
    case Regex.run(~r/^(#+)\s+(.+?)\s*#*\s*$/, line, capture: :all_but_first) do
      [hashes, text] -> {String.length(hashes), text}
      _ -> nil
    end
  end

  def blank?(body), do: Enum.all?(body, &(String.trim(&1) == ""))

  def own_marker?(line), do: Regex.match?(@own_marker, line)

  def indent(line) do
    [spaces] = Regex.run(~r/^[ \t]*/, line)
    spaces |> String.replace("\t", "    ") |> String.length()
  end

  # A scan error at line `no` (§11.11): recorded, never raised, so the scan reads on to the
  # end of the file and every error is reported at once.
  def fail(st, no, why),
    do: %{st | errors: [%{file: st.file, line: no, message: why} | st.errors]}
end
