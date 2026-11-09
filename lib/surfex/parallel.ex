defmodule Surfex.Parallel do
  @moduledoc false
  # A map over independent work on every core, with the results in input order and an error
  # raised as the sequential map would raise it (§12, #379): reading the log and scanning
  # files are per line and per file, and what follows sorts anyway.

  @doc """
  `Enum.map(list, fun)`, on up to one process per scheduler. The results come back in input
  order. A raise in `fun` is raised here, the same exception with its stacktrace.
  """
  @spec map([term], (term -> term)) :: [term]
  def map(list, fun) when length(list) < 2, do: Enum.map(list, fun)

  def map(list, fun) do
    {:ok, supervisor} = Task.Supervisor.start_link()

    results =
      supervisor
      |> Task.Supervisor.async_stream_nolink(list, fun,
        ordered: true,
        timeout: :infinity,
        max_concurrency: System.schedulers_online()
      )
      |> Enum.map(fn
        {:ok, value} -> {:ok, value}
        {:exit, reason} -> {:exit, reason}
      end)

    Supervisor.stop(supervisor)
    Enum.map(results, &unwrap/1)
  end

  @doc "`map/2` over `list` in chunks of `size`, flattened: for many small pieces of work."
  @spec chunked([term], pos_integer, (term -> term)) :: [term]
  def chunked(list, size, fun),
    do: list |> Enum.chunk_every(size) |> map(&Enum.map(&1, fun)) |> Enum.concat()

  defp unwrap({:ok, value}), do: value

  # A task that raised exits with the exception and where it was raised.
  defp unwrap({:exit, {%{__exception__: true} = exception, stacktrace}}),
    do: reraise(exception, stacktrace)

  defp unwrap({:exit, reason}), do: exit(reason)
end
