# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb do
  @moduledoc """
  Shared setup for every Phoenix module in Cartulary's web layer.

  Each function here returns a quoted block of `use`/`import`/alias statements, and
  `use CartularyWeb, :controller` (or `:html`, `:live_view`, `:router`, `:channel`) splices the
  matching block into the calling module. It exists so that the Phoenix modules in this
  project — the JSON API controllers used by agents and the curator browser UI — each pick up
  one agreed set of helpers instead of assembling their own. The MCP endpoint is a forwarded
  third-party router and does not go through this module.

      use CartularyWeb, :controller
      use CartularyWeb, :html

  What this module deliberately does not do:

  - It never resolves identity, Account, or authorization. That happens in the router's
    authentication plug for HTTP routes and in the governance live-session mount hook for the
    browser UI. Nothing in the web layer may take an Account from a header, a query parameter,
    or a request body.
  - It never defines functions inside the quoted blocks. Every block is expanded into every
    controller, component, LiveView, and channel, so a function defined here would be copied
    into all of them, cost compile time, and be impossible to test on its own. Put real logic
    in a named module and import that module from the relevant block instead.
  """

  @doc """
  Directories and files under `priv/static` that the endpoint is allowed to serve.

  Anything not listed here is invisible to the browser even if the file exists on disk, so a
  stray dump or fixture left in `priv/static` cannot leak over HTTP. The endpoint uses this
  list for static serving and the verified-routes setup uses it to recognise static paths.
  """
  def static_paths, do: ~w(assets fonts images favicon.ico robots.txt)

  @doc """
  Setup for the router module: the Phoenix router plus the imports its pipelines need.

  Route helper generation is off; routes are written with the compile-time verified `~p`
  sigil instead, so a typo in a path fails the build rather than 404ing at runtime.
  """
  def router do
    quote do
      use Phoenix.Router, helpers: false

      # Router pipelines call these as function plugs (`accepts`, `fetch_session`,
      # `protect_from_forgery`, `put_secure_browser_headers`), and `live_session` comes
      # from the LiveView router import.
      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  @doc """
  Setup for Phoenix channel modules. No channel module exists in this project today.
  """
  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  @doc """
  Setup for controller modules serving HTML and JSON.

  Both formats are enabled because the same web layer answers the agent-facing JSON API and
  the small browser sign-in surface. On the authenticated routes a controller reads the actor
  from `conn.assigns.current_actor`, which the authentication plug puts there; it must not
  reconstruct an Account from request data.
  """
  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  @doc """
  Setup for LiveView modules.

  `layout: false` means a LiveView renders straight into the root layout with no intermediate
  application layout — the root layout is the only HTML shell in this project, so adding a
  second one would duplicate the document head and the socket bootstrap script.

  A LiveView is never authenticated by the fact that it mounted. The curator UI re-verifies
  the session token in an `on_mount` hook on every mount, including the WebSocket reconnect,
  because the initial HTTP request and the socket connection are separate trust events.
  """
  def live_view do
    quote do
      use Phoenix.LiveView, layout: false

      unquote(html_helpers())
    end
  end

  @doc """
  Setup for stateless function-component modules, including the layouts.
  """
  def html do
    quote do
      use Phoenix.Component

      unquote(html_helpers())
    end
  end

  @doc """
  Rendering helpers shared by LiveViews and function components.

  Kept separate from `html/0` so `live_view/0` can reuse exactly the same helper set; a
  template must behave identically whether it is rendered statically or over the socket.
  """
  def html_helpers do
    quote do
      import Phoenix.HTML
      import Phoenix.Component

      unquote(verified_routes())
    end
  end

  @doc """
  Enables the `~p` sigil, which checks every path against the router at compile time.

  `statics:` tells the sigil which prefixes are served as files rather than routed, so
  referencing an asset does not fail verification.
  """
  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: CartularyWeb.Endpoint,
        router: CartularyWeb.Router,
        statics: CartularyWeb.static_paths()
    end
  end

  @doc """
  Expands `use CartularyWeb, :which` into the quoted block returned by the function named
  `which` in this module.

  `which` must be one of `:router`, `:channel`, `:controller`, `:live_view`, `:html`,
  `:html_helpers`, or `:verified_routes`. Any other atom raises `UndefinedFunctionError` at
  compile time, which is the intended failure: an unrecognised profile is a typo, not a
  fallback case.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
