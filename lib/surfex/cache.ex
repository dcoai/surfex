defmodule Surfex.Cache do
  @moduledoc false
  # Local caches of work a command already did on the same input (spec §12.2, #382, #383).
  #
  # A cache lives in `.surfex/cache/`, which ignores itself in git: it is never committed,
  # merged or judged, and deleting it only costs time. Every cache is keyed on its input,
  # so it can't give a result the work wouldn't, and every file carries:
  #
  #   * a **fingerprint** of the code that made it (module digests, Elixir and OTP
  #     versions): a file from other code is not used;
  #   * the **SHA-256 of its payload**: a file that was truncated or damaged is not used.
  #
  # A file that isn't used is rebuilt by the next write. Writes go to a temporary file and
  # are renamed into place, so a reader never sees half a file; a write that fails (a
  # read-only checkout) is skipped, because a cache must never fail a read.

  @magic "surfex-cache-1\n"

  @doc "The cache directory under a project root."
  @spec dir(String.t()) :: String.t()
  def dir(root), do: Path.join(Surfex.Log.dir(root), "cache")

  @doc "A fingerprint of the given modules' code and of the Elixir and OTP running them."
  @spec fingerprint([module()]) :: term()
  def fingerprint(modules),
    do:
      {Enum.map(modules, & &1.module_info(:md5)), System.version(),
       :erlang.system_info(:otp_release)}

  @doc "The term stored under `name` with this fingerprint, or `:none`."
  @spec read(String.t(), String.t(), term()) :: {:ok, term()} | :none
  def read(root, name, fingerprint) do
    with {:ok, <<@magic, sum::binary-size(32), payload::binary>>} <-
           File.read(Path.join(dir(root), name)),
         true <- :crypto.hash(:sha256, payload) == sum,
         {^fingerprint, term} <- :erlang.binary_to_term(payload) do
      {:ok, term}
    else
      _ -> :none
    end
  end

  @doc "Stores `term` under `name` with this fingerprint, or skips it if it can't be written."
  @spec write(String.t(), String.t(), term(), term()) :: :ok
  def write(root, name, fingerprint, term) do
    dir = dir(root)
    payload = :erlang.term_to_binary({fingerprint, term})
    target = Path.join(dir, name)
    temporary = "#{target}.#{System.unique_integer([:positive])}.tmp"

    # Only under an existing log directory: a cache must never make a project look like
    # it keeps a log.
    with true <- File.dir?(Path.dirname(dir)),
         :ok <- mkdir(dir),
         :ok <- ignore_itself(dir),
         :ok <- File.write(temporary, [@magic, :crypto.hash(:sha256, payload), payload]),
         :ok <- File.rename(temporary, target) do
      :ok
    else
      _ ->
        File.rm(temporary)
        :ok
    end
  end

  defp mkdir(dir), do: if(File.dir?(dir), do: :ok, else: File.mkdir(dir))

  defp ignore_itself(dir) do
    ignore = Path.join(dir, ".gitignore")
    if File.exists?(ignore), do: :ok, else: File.write(ignore, "*\n")
  end
end
