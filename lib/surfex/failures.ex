defmodule Surfex.Failures do
  @moduledoc false
  # Each test's failure history, read from its transitions (spec §17 `failure-classes`,
  # `failure-judgements`; #405, #408): every flip with a class saying what differed from
  # the run before it, and the judgements people and agents recorded on it.
  #
  # The class is mechanical, an input to a judgement rather than a verdict: a flip on a
  # commit that changed code can still be a flake that happened to flip there. So a
  # judgement is its own line in `.surfex/failure_judgements.log`, committed and
  # union-merged like the transitions, and never edits a transition.

  @judgements "failure_judgements.log"

  @type judgement :: %{
          test: String.t(),
          at: String.t(),
          note: String.t(),
          by: String.t() | nil,
          judged_at: String.t()
        }
  @type class :: :nondeterministic | :test_changed | :code_changed | :recurred | :new | :unknown
  @type history :: %{
          test: String.t(),
          state: :passed | :failed,
          renamed_from: [String.t()],
          flips: [map]
        }

  @doc "Where judgements live: `.surfex/failure_judgements.log` under `root`."
  @spec judgements_path(String.t()) :: String.t()
  def judgements_path(root), do: Path.join(Surfex.Log.dir(root), @judgements)

  @doc "Every judgement, in the order they were made."
  @spec judgements(String.t()) :: [judgement]
  def judgements(root) do
    case Surfex.Files.read(judgements_path(root)) do
      {:ok, bytes} ->
        bytes
        |> String.split("\n", trim: true)
        |> Enum.map(&decode_judgement/1)
        |> Enum.sort_by(&{&1.judged_at, &1.test, &1.at})

      {:error, :enoent} ->
        []
    end
  end

  @doc """
  Records a judgement on `test`'s transition at `at`, or its latest when `at` is nil.
  Refused when the test has no such transition. `test` may be an id the test had before
  a rename (`histories/3`).
  """
  @spec judge(
          String.t(),
          [map],
          %{String.t() => String.t()},
          String.t(),
          String.t() | nil,
          keyword
        ) ::
          {:ok, judgement} | {:error, String.t()}
  def judge(root, transitions, renames, test, at, meta) do
    test = Map.get(renames, test, test)
    flips = Enum.filter(transitions, &(Map.get(renames, &1.test, &1.test) == test))

    flip =
      case at do
        nil -> List.last(flips)
        at -> Enum.find(flips, &(&1.at == at))
      end

    case flip do
      nil ->
        {:error,
         if(flips == [],
           do: "#{test} has no transitions",
           else:
             "#{test} has no transition at #{at}: its transitions are at #{Enum.map_join(flips, ", ", & &1.at)}"
         )}

      flip ->
        judgement = %{
          test: test,
          at: flip.at,
          note: Keyword.fetch!(meta, :note),
          by: meta[:by],
          judged_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }

        File.write!(judgements_path(root), [Surfex.JSON.encode(judgement), "\n"], [:append])
        {:ok, judgement}
    end
  end

  @doc """
  Old test ids carried to their current one: a test id no longer scanned whose last
  transition's version is exactly one scanned test's version. A renamed module, describe
  or file is the same version under a new id (§14); a version two tests share is left alone.
  """
  @spec renames([map], %{String.t() => String.t()}) :: %{String.t() => String.t()}
  def renames(transitions, scanned) do
    by_version = Enum.group_by(scanned, fn {_id, hash} -> hash end, fn {id, _} -> id end)

    for {test, flips} <- Enum.group_by(transitions, & &1.test),
        not Map.has_key?(scanned, test),
        [current] <- [Map.get(by_version, List.last(flips).version, [])],
        into: %{},
        do: {test, current}
  end

  @doc """
  Each test's history, by current id: its state, the ids it had before, and its flips in
  time order, each with its class and judgements.
  """
  @spec histories([map], [judgement], %{String.t() => String.t()}) :: [history]
  def histories(transitions, judgements, renames) do
    current = &Map.get(renames, &1, &1)
    judged = Enum.group_by(judgements, &{current.(&1.test), &1.at})

    transitions
    |> Enum.group_by(&current.(&1.test))
    |> Enum.map(fn {test, flips} ->
      flips = Enum.sort_by(flips, &{&1.at, &1.run})

      classed =
        flips
        |> Enum.with_index()
        |> Enum.map(fn {flip, i} ->
          flip
          |> Map.put(:class, class(flip, Enum.take(flips, i)))
          |> Map.put(:judgements, Map.get(judged, {test, flip.at}, []))
        end)

      %{
        test: test,
        state: List.last(flips).to,
        renamed_from: flips |> Enum.map(& &1.test) |> Enum.uniq() |> Enum.reject(&(&1 == test)),
        flips: classed
      }
    end)
    |> Enum.sort_by(& &1.test)
  end

  @doc """
  What differed from the run before a flip: `recurred` when a failure with the same digest
  came back after a fail→pass that changed the test or its code (a fix that didn't hold);
  otherwise `test_changed`, `code_changed`, or `nondeterministic` when nothing did. With
  nothing to compare against, `new` for a test's first flip and `unknown` after.
  """
  @spec class(map, [map]) :: class
  def class(flip, earlier) do
    cond do
      recurred?(flip, earlier) -> :recurred
      flip.changed == nil -> if earlier == [], do: :new, else: :unknown
      flip.changed.test -> :test_changed
      flip.changed.code != [] -> :code_changed
      true -> :nondeterministic
    end
  end

  defp recurred?(%{to: :failed, failure: %{digest: digest}}, earlier) do
    earlier
    |> Enum.drop_while(&(not match?(%{to: :failed, failure: %{digest: ^digest}}, &1)))
    |> Enum.any?(&(&1.to == :passed and fixed?(&1.changed)))
  end

  defp recurred?(_flip, _earlier), do: false

  defp fixed?(%{test: test, code: code}), do: test or code != []
  defp fixed?(nil), do: false

  defp decode_judgement(line) do
    case Surfex.Log.Entry.json(line) do
      %{"test" => test, "at" => at, "note" => note, "judged_at" => judged_at} = map
      when is_binary(test) and is_binary(at) and is_binary(note) ->
        %{test: test, at: at, note: note, by: map["by"], judged_at: judged_at}

      _ ->
        raise ArgumentError, "not a failure judgement: #{String.slice(line, 0, 120)}"
    end
  end
end
