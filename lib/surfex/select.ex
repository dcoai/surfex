defmodule Surfex.Select do
  @moduledoc """
  A requirement's tests as surfex reads them (§11): every test whose declarations resolve
  to a unit, a list's members included. `mix test --only verifies:id` selects a test by
  none of a list's several ids, since ExUnit compares a list tag as one string; this
  selects by what the test declares, and `args/1` hands ExUnit their locations, which its
  location filter selects exactly. `mix surfex.test` runs them.
  """

  alias Surfex.Scan

  @doc """
  The tests declaring any of `refs`, each resolved as a declaration is
  (`Surfex.Scan.resolve/2`), each test once, in file and line order. With `within: true`,
  also the tests declaring a unit inside one: a block, hint or row whose `within` chain
  reaches it. A ref that is no spec unit, more than one, or that no test declares is an
  error, every such ref named in it: selecting nothing would run nothing, and pass. With
  `unit_refs:` (the project's, §11.1) a ref may be written in the project's own citation
  form.
  """
  @spec tests([Scan.t()], [String.t()], keyword) :: {:ok, [Scan.t()]} | {:error, String.t()}
  def tests(scans, refs, opts \\ []) do
    within? = Keyword.get(opts, :within, false)

    parents =
      for %Scan{kind: :spec, id: id, within: w} <- scans, w != nil, into: %{}, do: {id, w}

    resolver = Scan.resolver(scans, Keyword.get(opts, :unit_refs, []))

    declared =
      for %Scan{kind: :test} = t <- scans,
          {:verifies, ref} <- t.declares,
          {:ok, unit} <- [Scan.resolve(resolver, ref)],
          do: {t, unit.id}

    results =
      for ref <- refs do
        case Scan.resolve(resolver, ref) do
          {:ok, unit} ->
            case for({t, u} <- declared, inside?(u, unit.id, within?, parents), do: t) do
              [] ->
                {:error, "no test declares #{unit.id}#{if within?, do: " or a unit inside it"}"}

              tests ->
                {:ok, tests}
            end

          {:error, :unknown} ->
            {:error, "#{ref} is no spec unit"}

          {:error, {:ambiguous, ids}} ->
            {:error, "#{ref} is more than one spec unit: #{Enum.join(ids, ", ")}"}
        end
      end

    case for({:error, message} <- results, do: message) do
      [] ->
        tests = for {:ok, tests} <- results, t <- tests, do: t

        {:ok,
         tests
         |> Enum.uniq_by(& &1.id)
         |> Enum.sort_by(fn %{location: %{file: f, lines: {first, _}}} -> {f, first} end)}

      errors ->
        {:error, Enum.join(errors, "; ")}
    end
  end

  @doc """
  Every test that declares a deviation (`@tag deviation:`, §11), in file and line order:
  what `mix surfex.test --deviations` runs, skips included, to check whether any is stale
  (§17). ExUnit includes a skipped test only by a filter on its skip reason
  (`deviation_args/1`), which would run any test skipped for the same reason as well; so a
  test that isn't a deviation, in one of their files, skipped for a deviation test's
  reason, is an error, naming both. So is a deviation test whose skip isn't a literal (it
  can't be included), and none at all: selecting nothing would run nothing, and pass.
  """
  @spec deviations([Scan.t()]) :: {:ok, [Scan.t()]} | {:error, String.t()}
  def deviations(scans) do
    tests = for %Scan{kind: :test} = t <- scans, do: t
    {deviant, others} = Enum.split_with(tests, &(&1.deviation != nil))
    files = MapSet.new(deviant, & &1.location.file)
    reasons = Map.new(for t <- deviant, is_binary(t.skip), do: {t.skip, t.id})

    shared =
      for t <- others,
          MapSet.member?(files, t.location.file),
          Map.has_key?(reasons, t.skip),
          do: "#{t.id} is skipped for the reason #{inspect(t.skip)} as #{reasons[t.skip]} is"

    unreadable =
      for t <- deviant,
          t.skip == :unreadable,
          do: "#{t.id}'s skip: isn't a literal, so it can't be included by its reason"

    cond do
      deviant == [] ->
        {:error, "no test declares a deviation"}

      shared ++ unreadable != [] ->
        {:error,
         Enum.join(shared ++ unreadable, "; ") <>
           ": give each deviation test a skip reason of its own, written literally"}

      true ->
        {:ok,
         Enum.sort_by(deviant, fn %{location: %{file: f, lines: {first, _}}} -> {f, first} end)}
    end
  end

  @doc """
  The `mix test` arguments that run exactly the deviation tests `tests` (`deviations/1`),
  skips included: their files, `--only location:FILE:LINE` for each, and `--include
  skip:REASON` for each skip reason among them. A location given as `FILE:LINE` would
  replace every `--include`, so a skipped test would stay skipped.
  """
  @spec deviation_args([Scan.t()]) :: [String.t()]
  def deviation_args(tests) do
    files = tests |> Enum.map(& &1.location.file) |> Enum.uniq()
    locations = for loc <- args(tests), do: ["--only", "location:#{loc}"]

    reasons =
      for %Scan{skip: r} <- tests, is_binary(r), uniq: true, do: ["--include", "skip:#{r}"]

    files ++ List.flatten(locations ++ reasons)
  end

  @doc """
  The `mix test` arguments that run exactly `tests`: each one's file and first line, once.
  Tests a comprehension defines share their line, and one location runs them all.
  """
  @spec args([Scan.t()]) :: [String.t()]
  def args(tests) do
    for %Scan{location: %{file: file, lines: {first, _}}} <- tests,
        uniq: true,
        do: "#{file}:#{first}"
  end

  defp inside?(unit, unit, _within?, _parents), do: true
  defp inside?(_unit, _target, false, _parents), do: false

  defp inside?(unit, target, true, parents) do
    case Map.fetch(parents, unit) do
      {:ok, parent} -> inside?(parent, target, true, parents)
      :error -> false
    end
  end
end
