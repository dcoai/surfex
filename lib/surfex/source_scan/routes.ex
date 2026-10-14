defmodule Surfex.SourceScan.Routes do
  @moduledoc false
  # Calls a test states through a framework rather than by name (§11, #206): a request to
  # a route the project's router maps, an event sent to the LiveView a route mounted, and
  # a message sent to a named GenServer. Each resolves deterministically from source, so
  # it is a call like any other and reach, the triangle and evidence follow it.

  alias Surfex.SourceScan.Calls

  @typedoc """
  One route as the router declares it: the HTTP verb (`:get` for a `live` route), the
  path's segments (`{:param, name}`, `{:glob, name}` or a literal), and what it runs: a
  LiveView module, or a controller module and action.
  """
  @type route :: %{
          verb: atom,
          segments: [String.t() | {:param, String.t()} | {:glob, String.t()}],
          live: boolean,
          module: String.t(),
          action: atom | nil
        }

  @verbs [:get, :post, :put, :patch, :delete, :options, :head]
  @events [
    :render_click,
    :render_submit,
    :render_change,
    :render_keydown,
    :render_keyup,
    :render_blur,
    :render_focus,
    :render_hook
  ]

  @doc """
  The routes of the router modules among `files` (`{path, quoted}`): those named, or,
  given `:discover`, every module an endpoint (`use Phoenix.Endpoint`) plugs that is
  defined in `files` and is a router (`use Phoenix.Router`, or `use App, :router`).
  A named router that isn't defined there raises.
  """
  @spec read([{String.t(), Macro.t()}], [String.t()] | :discover) :: [route]
  def read(files, routers) do
    modules = for {_path, ast} <- files, m <- defmodules(ast), into: %{}, do: m

    names =
      case routers do
        :discover ->
          for {_name, body} <- modules,
              endpoint?(body),
              plugged <- plugged(body),
              Map.has_key?(modules, plugged),
              router?(modules[plugged]),
              uniq: true,
              do: plugged

        named ->
          for name <- named do
            unless Map.has_key?(modules, name),
              do: raise(ArgumentError, "router: #{name} isn't defined in the scanned source")

            name
          end
      end

    Enum.flat_map(names, &routes(modules[&1]))
  end

  # ── Reading a router ───────────────────────────────────────────────────

  defp defmodules(ast) do
    {_, found} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _, [{:__aliases__, _, parts}, [do: body]]} = node, acc ->
          if Enum.all?(parts, &is_atom/1),
            do: {node, [{Enum.map_join(parts, ".", &Atom.to_string/1), body} | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp endpoint?(body),
    do:
      Enum.any?(
        exprs(body),
        &match?({:use, _, [{:__aliases__, _, [:Phoenix, :Endpoint]} | _]}, &1)
      )

  defp router?(body) do
    Enum.any?(exprs(body), fn
      {:use, _, [{:__aliases__, _, [:Phoenix, :Router]} | _]} -> true
      {:use, _, [_app, :router]} -> true
      _ -> false
    end)
  end

  defp plugged(body) do
    aliases = Calls.aliases(exprs(body))

    for {:plug, _, [{:__aliases__, _, parts} | _]} <- exprs(body),
        do: Calls.expand(parts, aliases)
  end

  # Every route in a router body, in declaration order: scopes join their paths and
  # aliases as Phoenix does, and a `live_session` or `pipe_through` changes neither.
  defp routes(body),
    do: walk(exprs(body), %{path: [], alias: nil, aliases: Calls.aliases(exprs(body))})

  defp walk(exprs, ctx), do: Enum.flat_map(exprs, &route(&1, ctx))

  defp route({:scope, _, args}, ctx) when is_list(args) do
    {opts, [[do: block]]} = Enum.split(args, -1)

    {path, alias_} =
      case opts do
        [path] when is_binary(path) -> {path, nil}
        [path, {:__aliases__, _, _} = a | _] when is_binary(path) -> {path, a}
        [path, kw] when is_binary(path) and is_list(kw) -> {path, kw[:alias]}
        [kw] when is_list(kw) -> {Keyword.get(kw, :path, "/"), kw[:alias]}
        _ -> {nil, nil}
      end

    if path == nil do
      []
    else
      walk(exprs(block), %{
        ctx
        | path: ctx.path ++ segments(path),
          alias: scoped(ctx, alias_)
      })
    end
  end

  defp route({:live_session, _, args}, ctx) when is_list(args) do
    case List.last(args) do
      [do: block] -> walk(exprs(block), ctx)
      _ -> []
    end
  end

  defp route({:live, _, [path, {:__aliases__, _, parts} | rest]}, ctx) when is_binary(path) do
    action = with [a | _] when is_atom(a) <- rest, do: a, else: (_ -> nil)

    [
      %{
        verb: :get,
        segments: ctx.path ++ segments(path),
        live: true,
        module: module(ctx, parts),
        action: action
      }
    ]
  end

  defp route({verb, _, [path, {:__aliases__, _, parts}, action | _]}, ctx)
       when verb in @verbs and is_binary(path) and is_atom(action) do
    [
      %{
        verb: verb,
        segments: ctx.path ++ segments(path),
        live: false,
        module: module(ctx, parts),
        action: action
      }
    ]
  end

  defp route(_other, _ctx), do: []

  defp scoped(ctx, nil), do: ctx.alias
  defp scoped(_ctx, false), do: nil
  defp scoped(ctx, {:__aliases__, _, parts}), do: module(ctx, parts)

  # A route's module under its scope's alias, as Phoenix joins them.
  defp module(%{alias: nil, aliases: aliases}, parts), do: Calls.expand(parts, aliases)

  defp module(%{alias: scope}, parts),
    do: Enum.join([scope | Enum.map(parts, &Atom.to_string/1)], ".")

  defp segments(path) do
    for s <- String.split(path, "/", trim: true) do
      case s do
        ":" <> name -> {:param, name}
        "*" <> name -> {:glob, name}
        literal -> literal
      end
    end
  end

  # ── What a test body drives ────────────────────────────────────────────

  @doc """
  The calls a body states through the framework (§11): each request to a route `routes`
  maps, each event sent to a LiveView a request in the same body mounted, and each message
  sent to a GenServer named by its module. `aliases` resolve the modules the body names.
  """
  @spec calls(Macro.t(), Calls.aliases(), [route]) :: [String.t()]
  def calls(body, aliases, routes) do
    body = unpipe(body)
    views = views(body, aliases, routes)

    {_, found} =
      Macro.prewalk(body, [], fn node, acc ->
        {node, drives(node, aliases, routes, views) ++ acc}
      end)

    found |> Enum.uniq() |> Enum.sort()
  end

  # A piped call is the call it makes: `conn |> live(path)` is `live(conn, path)`.
  defp unpipe(ast) do
    Macro.postwalk(ast, fn
      {:|>, _, [lhs, {{:., _, _} = dot, meta, args}]} when is_list(args) ->
        {dot, meta, [lhs | args]}

      {:|>, _, [lhs, {fun, meta, args}]} when is_atom(fun) and is_list(args) ->
        {fun, meta, [lhs | args]}

      node ->
        node
    end)
  end

  # Each variable bound to the LiveView a request mounted: `{:ok, view, _html} = live(…)`.
  defp views(body, aliases, routes) do
    {_, found} =
      Macro.prewalk(body, %{}, fn
        {:=, _, [{:{}, _, [:ok, {var, _, ctx} | _]}, rhs]} = node, acc
        when is_atom(var) and is_atom(ctx) ->
          case mounted(rhs, aliases, routes) do
            nil -> {node, acc}
            module -> {node, Map.put(acc, var, module)}
          end

        node, acc ->
          {node, acc}
      end)

    found
  end

  # The LiveView a request mounts, or nil.
  defp mounted(call, aliases, routes) do
    case request(call, aliases, routes) do
      {:live, module} -> module
      _ -> nil
    end
  end

  # What one node drives: a request's target, an event's handler, a message's callback.
  defp drives(node, aliases, routes, views) do
    case request(node, aliases, routes) do
      {:live, module} ->
        [module, Calls.call(module, :mount, 3), Calls.call(module, :handle_params, 3)]

      {:isolated, module} ->
        [module, Calls.call(module, :mount, 3)]

      {:action, module, action} ->
        [module, Calls.call(module, action, 2)]

      nil ->
        event(node, views) ++ message(node, aliases)
    end
  end

  # A request: `live/2`, a verb (`get/2`, …) or `live_isolated/2,3`, local or qualified.
  defp request({fun, _, [_conn, path | _]}, _aliases, routes)
       when fun == :live or fun in @verbs,
       do: route_to(if(fun == :live, do: :get, else: fun), path, routes)

  defp request({:live_isolated, _, [_conn, {:__aliases__, _, parts} | _]}, aliases, _routes),
    do: {:isolated, Calls.expand(parts, aliases)}

  defp request({{:., _, [{:__aliases__, _, [:Phoenix, test]}, fun]}, meta, args}, aliases, routes)
       when test in [:LiveViewTest, :ConnTest] and is_list(args),
       do: request({fun, meta, args}, aliases, routes)

  defp request(_node, _aliases, _routes), do: nil

  # The first route, in the router's order, that a literal path matches for `verb`.
  defp route_to(verb, path, routes) do
    with segments when is_list(segments) <- path_segments(path),
         %{} = route <- Enum.find(routes, &(&1.verb == verb and matches?(&1.segments, segments))) do
      if route.live, do: {:live, route.module}, else: {:action, route.module, route.action}
    else
      _ -> nil
    end
  end

  # A path's segments: a literal string, or a string or `~p` with interpolations, each
  # segment that holds one dynamic. The query string is not part of the route.
  defp path_segments(path) when is_binary(path), do: split(path)

  defp path_segments({:sigil_p, _, [{:<<>>, _, parts}, _mods]}), do: interpolated(parts)
  defp path_segments({:<<>>, _, parts}), do: interpolated(parts)
  defp path_segments(_other), do: nil

  @hole "\u0000"

  defp interpolated(parts) do
    parts
    |> Enum.map_join(fn
      text when is_binary(text) -> text
      _interpolation -> @hole
    end)
    |> split()
  end

  defp split(path) do
    [path | _] = String.split(path, "?", parts: 2)

    for s <- String.split(path, "/", trim: true),
        do: if(String.contains?(s, @hole), do: :dynamic, else: s)
  end

  # A literal segment matches itself or a param; a dynamic one only a param, since what it
  # holds is known only when the test runs. A glob takes the rest.
  defp matches?([], []), do: true
  defp matches?([{:glob, _} | _], _rest), do: true
  defp matches?([{:param, _} | r], [_ | s]), do: matches?(r, s)
  defp matches?([lit | r], [lit | s]) when is_binary(lit), do: matches?(r, s)
  defp matches?(_route, _path), do: false

  # An event to a mounted view: `render_click(view, "event", …)` and the other `render_*`
  # functions, given the view or an element or form of it.
  defp event({fun, _, [target | _]}, views) when fun in @events do
    case view_of(target, views) do
      nil -> []
      module -> [Calls.call(module, :handle_event, 3)]
    end
  end

  defp event(_node, _views), do: []

  defp view_of({var, _, ctx}, views) when is_atom(var) and is_atom(ctx), do: Map.get(views, var)

  defp view_of({wrap, _, [inner | _]}, views) when wrap in [:element, :form],
    do: view_of(inner, views)

  defp view_of(_other, _views), do: nil

  # A message to a GenServer named by its module: `GenServer.call(Mod, msg)` runs
  # `Mod.handle_call/3`, `GenServer.cast(Mod, msg)` its `handle_cast/2`.
  defp message(
         {{:., _, [{:__aliases__, _, [:GenServer]}, fun]}, _, [{:__aliases__, _, parts} | _]},
         aliases
       )
       when fun in [:call, :cast] do
    module = Calls.expand(parts, aliases)
    callback = if fun == :call, do: {:handle_call, 3}, else: {:handle_cast, 2}
    [module, Calls.call(module, elem(callback, 0), elem(callback, 1))]
  end

  defp message(_node, _aliases), do: []

  defp exprs({:__block__, _, list}), do: list
  defp exprs(nil), do: []
  defp exprs(one), do: [one]
end
