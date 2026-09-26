defmodule Surfex.Surface do
  @moduledoc """
  A project's own golden, gated by `mix surfex.goldens` alongside its trace.

  The part only the project can write is the scanner: what its surface *is* (the
  endpoints a router declares, the escape sequences a terminal emits, the actions a
  model defines). Implement `c:spec/1` to return the golden as data, and list the module
  in `.surfex.exs`:

      goldens: [:trace, {"API_SURFACE.md", MyApp.Goldens.Api, []}]

  `Surfex.Golden.render/1` renders the spec, and the runner writes it or checks it. The
  surface module is project code, so the runner compiles the project first.
  """

  @doc "The golden, as a `Surfex.Golden` spec. `opts` is the entry's third element."
  @callback spec(opts :: keyword) :: Surfex.Golden.spec()
end
