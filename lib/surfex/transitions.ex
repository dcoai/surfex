defmodule Surfex.Transitions do
  @moduledoc false
  # Each test's pass/fail transitions (spec §17 `failure-transitions`, #405, #407).
  #
  # Evidence is scratch: lost on a clean build, separate in each worktree, and far too large
  # to commit. What a failure history needs is small: the runs where a test's result
  # flipped. So the end of a run appends one line per flip to `.surfex/transitions.log`,
  # which is committed and union-merged as the relation log is (its `.surfex/*.log` rule).
  # A test's state is its last transition's `to`; a test with none has never failed. A
  # stable suite writes nothing, and a test that stays red costs one line.

  alias Surfex.Evidence

  @file_name "transitions.log"

  @type t :: %{
          required(:test) => String.t(),
          required(:version) => String.t(),
          required(:from) => :passed | :failed,
          required(:to) => :passed | :failed,
          required(:at) => String.t(),
          required(:run) => String.t(),
          required(:commit) => String.t() | nil,
          required(:code) => String.t(),
          required(:changed) => %{test: boolean, code: [String.t()]} | nil,
          optional(:failure) => Evidence.failure(),
          optional(:failed_runs) => non_neg_integer | nil
        }

  @doc "Where a project's transitions live: `.surfex/transitions.log` under `root`."
  @spec path(String.t()) :: String.t()
  def path(root), do: Path.join(Surfex.Log.dir(root), @file_name)

  @doc """
  Every transition, ordered by time, then run, then test: the order two branches' lines
  have once merged, wherever each was written. `[]` when there is no file.
  """
  @spec load(String.t()) :: [t]
  def load(root) do
    case load_file(path(root)) do
      {:ok, transitions} -> transitions
      {:error, :enoent} -> []
    end
  end

  @doc """
  The transitions in the file at `path`, in load/1's order: a project's own, or a CI job's
  (`record/4` with an output path).
  """
  @spec load_file(String.t()) :: {:ok, [t]} | {:error, File.posix()}
  def load_file(path) do
    with {:ok, bytes} <- Surfex.Files.read(path) do
      {:ok, bytes |> String.split("\n", trim: true) |> Enum.map(&decode/1) |> combined()}
    end
  end

  @doc """
  Several files' transitions as one history: each line once (a line is its test, run and
  ends), ordered by time, then run, then test.
  """
  @spec combined([t]) :: [t]
  def combined(transitions) do
    transitions
    |> Enum.uniq_by(&key/1)
    |> Enum.sort_by(&{&1.at, &1.run, &1.test})
  end

  defp key(t), do: {t.test, t.run, t.from, t.to}

  @doc """
  Appends to the project's transitions each line of `files`' transitions it doesn't have
  yet, once, and returns `{added, already there}`. The project must keep a log.
  """
  @spec ingest(String.t(), [[t]]) :: {[t], [t]}
  def ingest(root, files) do
    have = MapSet.new(load(root), &key/1)

    {added, present} =
      files
      |> Enum.concat()
      |> combined()
      |> Enum.split_with(&(not MapSet.member?(have, key(&1))))

    if added != [], do: File.write!(path(root), Enum.map(added, &[encode(&1), "\n"]), [:append])
    {added, present}
  end

  @doc "Each test's last transition: its state is that transition's `to`."
  @spec last([t]) :: %{String.t() => t}
  def last(transitions), do: Map.new(transitions, &{&1.test, &1})

  @doc """
  Appends the transitions a run's `records` make, and returns them. Only in a project that
  keeps a log (`.surfex/`). A passed or failed record whose result differs from its test's
  state is a transition; an excluded or skipped one never is. `evidence` gives the
  evidence, read only when there is a transition, to find the opposite result's versions
  and count the failed runs a fail→pass ends.

  With an output path `out` (a CI job's artifact), the lines go there instead, whether or
  not the project keeps a log, and the state they're judged against is the project's
  transitions with the lines already in `out`: the run never writes the checkout.
  """
  @spec record(String.t(), [Evidence.t()], (-> [Evidence.t()]), String.t() | nil) :: [t]
  def record(root, records, evidence, out \\ nil) do
    if out != nil or File.dir?(Surfex.Log.dir(root)) do
      written =
        case out && load_file(out) do
          {:ok, transitions} -> transitions
          _none -> []
        end

      last = (load(root) ++ written) |> combined() |> last()

      flips =
        for %{result: to} = r <- records,
            to in [:passed, :failed],
            from = state(last, r.test),
            from != to,
            do: {r, from, Map.get(last, r.test)}

      case flips do
        [] -> []
        flips -> append(root, out || path(root), flips, evidence.())
      end
    else
      []
    end
  end

  defp state(last, test) do
    case last do
      %{^test => %{to: to}} -> to
      _ -> :passed
    end
  end

  defp append(root, target, flips, evidence) do
    commit = commit(root)
    by_test = Enum.group_by(evidence, & &1.test)

    lines =
      for {r, from, previous} <- flips do
        before = by_test |> Map.get(r.test, []) |> Enum.reject(&(&1.run == r.run))

        %{
          test: r.test,
          version: r.test_hash,
          from: from,
          to: r.result,
          at: r.at,
          run: r.run,
          commit: commit,
          code: code_digest(r.code),
          changed: changed(r, before, from, previous)
        }
        |> detail(r, previous, before)
      end

    File.mkdir_p!(Path.dirname(target))
    File.write!(target, Enum.map(lines, &[encode(&1), "\n"]), [:append])
    lines
  end

  # What differs from the last run with the opposite result: the test's version, and the
  # code it reached whose versions differ. nil when no such run is in the evidence.
  #
  # Without that run (a CI job's fresh build, a clean build), the test's last transition
  # was the opposite result too, and holds its version and code digest: with the same
  # digest, no reached code changed, and the versions say whether the test did. A different
  # digest says code changed but not which, so it stays nil.
  defp changed(r, before, from, previous) do
    case before |> Enum.filter(&(&1.result == from)) |> List.last() do
      nil ->
        case previous do
          %{to: ^from, code: digest, version: version} ->
            if digest == code_digest(r.code),
              do: %{test: version != r.test_hash, code: []},
              else: nil

          _ ->
            nil
        end

      opposite ->
        ids = Map.keys(opposite.code) ++ Map.keys(r.code)

        %{
          test: opposite.test_hash != r.test_hash,
          code:
            ids
            |> Enum.uniq()
            |> Enum.filter(&(Map.get(opposite.code, &1) != Map.get(r.code, &1)))
            |> Enum.sort()
        }
    end
  end

  # A pass→fail carries its failure; a fail→pass the failed runs since the pass→fail, when
  # the evidence still holds that run (otherwise the count isn't known: nil).
  defp detail(line, %{result: :failed} = r, _previous, _before) do
    case r do
      %{failure: failure} -> Map.put(line, :failure, failure)
      _ -> line
    end
  end

  defp detail(line, %{result: :passed}, previous, before) do
    count =
      case previous do
        %{to: :failed, run: run, at: at} ->
          if Enum.any?(before, &(&1.run == run)),
            do: Enum.count(before, &(&1.result == :failed and &1.at >= at)),
            else: nil

        nil ->
          nil
      end

    Map.put(line, :failed_runs, count)
  end

  # The digest of the code versions a test reached.
  defp code_digest(code) do
    code
    |> Enum.sort()
    |> Enum.map(fn {id, hash} -> [id, "=", to_string(hash), "\n"] end)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  # The commit the run was on, or nil outside a git work tree.
  defp commit(root) do
    with git when is_binary(git) <- System.find_executable("git"),
         {sha, 0} <- System.cmd(git, ["rev-parse", "HEAD"], cd: root, stderr_to_stdout: true) do
      String.trim(sha)
    else
      _ -> nil
    end
  end

  defp encode(line) do
    line
    |> Map.new(fn
      {key, value} when key in [:from, :to] -> {Atom.to_string(key), Atom.to_string(value)}
      {:changed, %{test: test, code: code}} -> {"changed", %{"test" => test, "code" => code}}
      {:failure, f} -> {"failure", Map.new(f, fn {k, v} -> {Atom.to_string(k), v} end)}
      {key, value} -> {Atom.to_string(key), value}
    end)
    |> Surfex.JSON.encode()
  end

  @fields ~w(test version from to at run commit code changed)
  @results %{"passed" => :passed, "failed" => :failed}

  # A line's transition. A line that isn't one raises, naming it: the file is written only
  # here and union-merged, so a bad line is damage.
  defp decode(line) do
    with %{} = map <- Surfex.Log.Entry.json(line),
         [] <- Enum.reject(@fields, &Map.has_key?(map, &1)),
         {:ok, from} <- Map.fetch(@results, map["from"]),
         {:ok, to} <- Map.fetch(@results, map["to"]) do
      %{
        test: map["test"],
        version: map["version"],
        from: from,
        to: to,
        at: map["at"],
        run: map["run"],
        commit: map["commit"],
        code: map["code"],
        changed: decode_changed(map["changed"])
      }
      |> put_optional(map)
    else
      _ -> raise ArgumentError, "not a transition: #{String.slice(line, 0, 120)}"
    end
  end

  defp decode_changed(nil), do: nil
  defp decode_changed(%{"test" => test, "code" => code}), do: %{test: test, code: code}

  defp put_optional(t, map) do
    t
    |> then(fn t ->
      case map do
        %{"failure" => f} ->
          Map.put(t, :failure, %{
            kind: f["kind"],
            line: f["line"],
            location: f["location"],
            seed: f["seed"],
            digest: f["digest"]
          })

        _ ->
          t
      end
    end)
    |> then(
      &if Map.has_key?(map, "failed_runs"),
        do: Map.put(&1, :failed_runs, map["failed_runs"]),
        else: &1
    )
  end
end
