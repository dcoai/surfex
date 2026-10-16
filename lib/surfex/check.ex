defmodule Surfex.Check do
  @moduledoc """
  Running declared checks (§11.4, §17.1): each check's command, in the project's root, and
  its result as evidence, in the file the test formatter writes (`Surfex.Evidence`).

  A check's evidence is a test's in form: its `test` is the check's id, its `test_hash`
  the check's declaration's version, and its `code` the versions of its inputs at the run.
  So a check discriminates as a test does (`Surfex.Evidence.red_then_green/3`): its
  declaration failed against one set of input versions and later passed against another.
  A command that exits 0 passed; any other status failed.

  `mix surfex.check` runs them.
  """

  alias Surfex.{Evidence, Scan}

  @typedoc "A check's `run:`: a string run with the shell, or an argv run with none."
  @type command :: String.t() | [String.t(), ...]

  @doc """
  The checks among `scans` that `ids` name, in id order; every check when `ids` is empty.
  An id no check has is an error naming it, as is a project with no checks: running
  nothing would pass in silence.
  """
  @spec select([Scan.t()], [String.t()]) :: {:ok, [Scan.t()]} | {:error, String.t()}
  def select(scans, ids) do
    checks = scans |> Enum.filter(&(&1.kind == :check)) |> Enum.sort_by(& &1.id)
    known = MapSet.new(checks, & &1.id)

    cond do
      checks == [] ->
        {:error, "no checks: declare them under checks: in .surfex.exs"}

      ids == [] ->
        {:ok, checks}

      (unknown = Enum.reject(ids, &MapSet.member?(known, &1))) != [] ->
        {:error, "no check has the id #{Enum.join(unknown, ", ")}"}

      true ->
        {:ok, Enum.filter(checks, &(&1.id in ids))}
    end
  end

  @doc """
  Runs each check's command with `shell` (by default `shell/2`, in `root`), in order, and
  gives one evidence record per check: passed when the command exits 0, failed otherwise,
  at the check's declaration's version against its inputs' versions as scanned before the
  run. One run id and time for them all, as a test run has.
  """
  @spec run([Scan.t()], String.t(), (command, String.t() -> non_neg_integer)) ::
          [Evidence.t()]
  def run(checks, root, shell \\ &shell/2) do
    run = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    at = DateTime.utc_now() |> DateTime.to_iso8601()

    checks
    |> Enum.with_index()
    |> Enum.map(fn {%Scan{kind: :check, check: check} = scan, seq} ->
      %{
        test: scan.id,
        test_hash: check.declaration,
        result: if(shell.(check.run, root) == 0, do: :passed, else: :failed),
        at: at,
        run: run,
        seq: seq,
        code: check.inputs
      }
    end)
  end

  @doc """
  Runs `command` in `root`, its output streamed to standard output, and gives its exit
  status: a string with the system's shell (`sh -c`), an argv with no shell, its first
  element the program (§11.4).
  """
  @spec shell(command, String.t()) :: non_neg_integer
  def shell(command, root) when is_binary(command), do: shell(["sh", "-c", command], root)

  def shell([program | args], root) do
    {_, status} =
      System.cmd(program, args, cd: root, into: IO.stream(), stderr_to_stdout: true)

    status
  end

  @doc "A check's command as one line to show: a string as written, an argv joined by spaces."
  @spec display(command) :: String.t()
  def display(command) when is_binary(command), do: command
  def display(argv), do: Enum.join(argv, " ")
end
