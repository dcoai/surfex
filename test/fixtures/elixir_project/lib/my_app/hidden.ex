defmodule MyApp.Hidden do
  @moduledoc false
  def secret, do: :x

  defmodule Visible do
    def shown, do: :y
  end
end

defmodule MyApp.Server do
  @behaviour GenServer

  @impl true
  def init(arg), do: {:ok, arg}

  @impl true
  @doc "Documented on purpose."
  def handle_call(msg, _from, state), do: {:reply, msg, state}

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)
end
