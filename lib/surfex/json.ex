defmodule Surfex.JSON do
  @moduledoc false
  # The JSON surfex writes for tools and agents (spec json-key-order, #394): every object's
  # keys in sorted order, at every depth, and `nil` as null.
  #
  # OTP's encoder writes a map's keys in the map's own order. For string keys that is a
  # fixed byte order, but for atom keys it is the order the VM created the atoms in, which
  # depends on what loaded first: `mix surfex.suggest --format json` changed its bytes
  # after a compile. It also writes `nil` as the string "nil".
  #
  # The relation log is not written here: its lines keep their canonical field order,
  # which entry ids depend on (`Surfex.Log.Entry`).

  @doc "`term` as JSON text, each object's keys sorted by name."
  @spec encode(term) :: String.t()
  def encode(term), do: term |> :json.encode(&value/2) |> IO.iodata_to_binary()

  defp value(nil, _encoder), do: "null"

  defp value(map, encoder) when is_map(map) do
    map
    |> Enum.map(fn {key, v} -> {key(key), v} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> :json.encode_key_value_list(encoder)
  end

  defp value(other, encoder), do: :json.encode_value(other, encoder)

  defp key(key) when is_binary(key), do: key
  defp key(key) when is_atom(key), do: Atom.to_string(key)
  defp key(key) when is_integer(key), do: Integer.to_string(key)
end
