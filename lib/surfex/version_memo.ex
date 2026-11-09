defmodule Surfex.VersionMemo do
  @moduledoc false
  # Definition versions remembered by content (spec §12.2, #383, #385). Hashing a definition
  # pretty-prints it, which was most of the time a scan took, and nearly every definition
  # is the same from one run to the next.
  #
  # The memo is a public ETS table that `Surfex.SourceScan.definition_hash/1` reads and fills
  # (its `remembered/2`): the SHA-256 of a metadata-stripped AST's external term format,
  # mapped to the version the hash gave that AST. It can't give a version the hash wouldn't.
  # This module opens it for a scan (`run/2`), and `Surfex.Parallel` hands it to its tasks
  # (`current/0`, `adopt/1`). Outside a scan `definition_hash/1` hashes as before and touches
  # no file. Sharing a table is always safe: a digest names one term, which has one version.
  #
  # Between runs it is kept in `.surfex/cache/` (`Surfex.Cache`), fingerprinted by
  # `Surfex.SourceScan`'s code and the Elixir and OTP running it, since a version is Elixir's
  # `Macro.to_string/1` output. Only a run that hashed something new saves it, and a version
  # unused through eight such saves in a row is dropped: the file follows the code as it is
  # now without forgetting what a command that scans less didn't use.
  #
  # A run that raises leaves its table in the process dictionary, where a later run in the
  # same process reuses it: still correct, as every table is, but not saved.

  # `Surfex.SourceScan`'s `@memo`: the process key it reads the table from.
  @key :surfex_version_memo
  @file_name "versions"
  @kept 8

  @doc "Runs `fun` with a memo for the project at `root`, saving what it learned."
  @spec run(String.t(), (-> result)) :: result when result: term
  def run(root, fun) do
    case current() do
      nil -> open(root, fun)
      _already -> fun.()
    end
  end

  @doc "The memo this process uses, if any: to hand to another process."
  @spec current :: :ets.tid() | nil
  def current, do: Process.get(@key)

  @doc "Uses `table` (from `current/0`) in this process; `nil` changes nothing."
  @spec adopt(:ets.tid() | nil) :: :ok
  def adopt(nil), do: :ok

  def adopt(table) do
    Process.put(@key, table)
    :ok
  end

  defp open(root, fun) do
    table = :ets.new(__MODULE__, [:set, :public, read_concurrency: true, write_concurrency: true])

    case Surfex.Cache.read(root, @file_name, fingerprint()) do
      {:ok, saved} -> :ets.insert(table, for({d, {v, unused}} <- saved, do: {d, v, unused + 1}))
      :none -> :ok
    end

    adopt(table)
    result = fun.()
    Process.delete(@key)

    if :ets.member(table, :learned) do
      saved =
        for {digest, version, unused} <- :ets.tab2list(table),
            is_binary(digest),
            unused <= @kept,
            into: %{},
            do: {digest, {version, unused}}

      Surfex.Cache.write(root, @file_name, fingerprint(), saved)
    end

    :ets.delete(table)
    result
  end

  defp fingerprint, do: Surfex.Cache.fingerprint([Surfex.SourceScan])
end
