defmodule Surfex.Files do
  @moduledoc false
  # Reads of surfex's large files: the relation log's segments, the cache's files and the
  # evidence (spec §12.2 `raw-reads`, #401).
  #
  # `File.read/1` and `File.read!/1` ask OTP's file server (`:file_server_2`) to read the
  # file, and it replies with the binary. An idle file server doesn't collect its garbage,
  # so it keeps the last binaries it handed out alive for as long as the command runs: on
  # apu, the 71 MB log after a check, and the whole 1.15 GB evidence file after reading it.
  # A raw read happens in the calling process, so the bytes go when the caller drops them.

  @doc "The file's bytes, read in the calling process: `File.read/1`'s result."
  @spec read(Path.t()) :: {:ok, binary()} | {:error, File.posix()}
  def read(path), do: :file.read_file(IO.chardata_to_string(path), [:raw])

  @doc "The file's bytes, read in the calling process; raises `File.Error` as `File.read!/1` does."
  @spec read!(Path.t()) :: binary()
  def read!(path) do
    case read(path) do
      {:ok, bytes} ->
        bytes

      {:error, reason} ->
        raise File.Error, reason: reason, action: "read file", path: IO.chardata_to_string(path)
    end
  end
end
