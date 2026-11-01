defmodule Surfex.Test.OwnLog do
  @moduledoc """
  The recurrence guard of #341: the test suite never changes the project's own relation
  log. Every test works on a copy or a tmp project; a test that resolved its root to this
  checkout instead would edit the log CI verifies right after the suite, and the failure
  would read as tampering ("does not match its content (edited?)").

  `guard/1` digests every file under `.surfex/` before the suite and, after it, fails the
  run naming each file that changed, appeared or went missing.
  """

  @doc "Every regular file under `dir`, relative to it, with the SHA-256 of its bytes."
  @spec digest(String.t()) :: %{String.t() => String.t()}
  def digest(dir) do
    for path <- Path.wildcard(Path.join(dir, "**/*"), match_dot: true),
        File.regular?(path),
        into: %{},
        do: {Path.relative_to(path, dir), :crypto.hash(:sha256, File.read!(path))}
  end

  @doc "What differs between two digests, one line per file, sorted; `[]` when nothing does."
  @spec changes(map, map) :: [String.t()]
  def changes(before, now) do
    (Map.keys(before) ++ Map.keys(now))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(fn file ->
      case {Map.fetch(before, file), Map.fetch(now, file)} do
        {same, same} -> []
        {:error, {:ok, _}} -> ["#{file} appeared"]
        {{:ok, _}, :error} -> ["#{file} went missing"]
        {{:ok, _}, {:ok, _}} -> ["#{file} changed"]
      end
    end)
  end

  @doc """
  Digests `root`'s `.surfex/` now and, after the suite, raises naming every file in it the
  suite changed, which fails `mix test`. Call it from `test/test_helper.exs`.
  """
  @spec guard(String.t()) :: :ok
  def guard(root) do
    dir = Path.join(root, ".surfex")
    before = digest(dir)

    ExUnit.after_suite(fn _result ->
      case changes(before, digest(dir)) do
        [] ->
          :ok

        changed ->
          raise """
          the test suite changed the project's own relation log (#{dir}):
            #{Enum.join(changed, "\n  ")}
          A test resolved its root to this checkout instead of a tmp project: every test that
          records must work on a copy. (Recording in another terminal while the suite runs
          trips this too.) Restore the log with `git checkout -- .surfex/`.
          """
      end
    end)
  end
end
