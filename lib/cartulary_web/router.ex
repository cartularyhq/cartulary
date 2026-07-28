# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.Router do
  @moduledoc """
  Every HTTP path into Cartulary, and the authentication each one demands.

  There are four kinds of caller and they are kept strictly apart:

  - **Anonymous.** Only the liveness/readiness probes, the password sign-in endpoint, and the
    curator sign-in form and its POST. No Account is resolved yet on these requests.
  - **Any authenticated identity** (`/api/v1` memory routes, `/mcp`). Requires
    `Authorization: Bearer <credential>`, where the credential is either a human sign-in token
    or an agent API key. This is the surface agents use.
  - **A human password identity** (`/api/v1/self/*`). A bearer token is not enough; the
    credential must have been minted by a password sign-in. An agent API key gets 403 here
    even if it belongs to the same peer, because contesting, redacting, and erasing one's own
    knowledge are personal decisions that a machine may not take on a person's behalf.
  - **A human curator browser session** (`/governance/*`). Cookie session plus CSRF plus a
    re-check on every LiveView mount, restricted to the account-admin and curator roles.

  **Account is derived from the credential, never from the request.** The authentication plug
  resolves the verified identity into an actor and installs that actor's Account as the Ash
  tenant for the rest of the request. No route reads an Account from a header, a query
  parameter, or a JSON body. An older account-key header and account fields inside request
  bodies are inert: they are ignored rather than honoured. Do not reintroduce a
  caller-supplied Account, even behind a debug flag — a caller that can name its tenant can
  name someone else's.

  Curator authority is not reachable over any machine-facing route. Approving, editing,
  rejecting, merging, deferring, promoting, and gate-rule administration exist only in the
  browser LiveView; the machine tool endpoint below exposes a fixed allowlist that contains
  none of them.
  """

  use CartularyWeb, :router

  # JSON transport only: no session, no CSRF, no cookies. Authentication is a separate
  # pipeline, so piping through :api alone leaves a route public.
  pipeline :api do
    plug :accepts, ["json"]
  end

  # Turns a bearer credential into an authenticated actor, then bills the request.
  #
  # Order is load-bearing. RequireIdentity halts with 401 before any controller runs and
  # assigns the actor plus the Ash tenant/actor context; MeterUsage registers a
  # before_send callback that reads that actor to write one usage-ledger row per response.
  # Swap the two and unauthenticated traffic would either crash the meter or be billed to
  # nobody.
  pipeline :authenticated_api do
    plug CartularyWeb.Plugs.RequireIdentity
    plug CartularyWeb.Plugs.MeterUsage
  end

  # The browser surface: cookie session, CSRF token check on every non-GET, the single HTML
  # shell, and a deliberately tight Content-Security-Policy.
  #
  # The policy allows only same-origin resources. `connect-src` additionally permits ws:/wss:
  # because LiveView holds a WebSocket. `script-src 'self'` bans inline script, which is why
  # the page bootstraps from a served .js file rather than an inline tag. `style-src` still
  # allows 'unsafe-inline' because the governance markup styles elements with plain `style`
  # attributes; removing that allowance requires moving those rules into a stylesheet first,
  # or the UI renders unstyled. `frame-ancestors 'none'` blocks click-jacking of curator
  # decision buttons, and `form-action 'self'` keeps the sign-in form from being retargeted.
  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_root_layout, html: {CartularyWeb.Layouts, :root}

    plug :put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; base-uri 'self'; connect-src 'self' ws: wss:; " <>
          "form-action 'self'; frame-ancestors 'none'; object-src 'none'; " <>
          "script-src 'self'; style-src 'self' 'unsafe-inline'"
    }
  end

  # Narrows an already-authenticated request to a human password identity, rejecting agent
  # API keys with 403. Must be piped after :authenticated_api, which is what supplies the
  # actor it inspects.
  pipeline :human_governance do
    plug CartularyWeb.Plugs.RequireHumanIdentity
  end

  scope "/api", CartularyWeb do
    pipe_through :api

    # Unauthenticated on purpose: container and load-balancer probes must answer before any
    # credential exists, and sign-in is where a credential is obtained in the first place.
    #
    # The probe payloads stay content-safe — component status, queue counts, model
    # identities, versions, and error classes only, never credentials or stored content —
    # because anyone who can reach the port can read them. Health also reports the
    # extractor/pipeline contract identity "f5-1"; that string names the extraction
    # behaviour clients are compiled against, so bumping it is a deliberate contract change
    # that owes a changelog entry and updated contract evidence, not a version cosmetic.
    get "/health", MemoryController, :health
    get "/ready", MemoryController, :ready

    # Exchanges an email and password for a short-lived bearer token, which the caller then
    # sends on the authenticated routes. A wrong email and a wrong password produce the same
    # opaque 401, so the response cannot be used to enumerate accounts.
    post "/auth/password", AuthController, :password

    scope "/v1" do
      pipe_through :authenticated_api

      # The memory surface shared by agents and humans. Writes here are raw observations
      # only: ingest records what was said and hands it to the extraction pipeline, which
      # is the only writer of governed knowledge. No route on this list can activate
      # knowledge or approve a proposal.
      post "/ingest", MemoryController, :ingest
      post "/ask", MemoryController, :ask
      post "/search", MemoryController, :search
      post "/context", MemoryController, :context
      post "/readiness", MemoryController, :readiness
      get "/knowledge", MemoryController, :knowledge
      get "/operations/costs", MemoryController, :costs
    end
  end

  scope "/governance", CartularyWeb do
    pipe_through :browser

    # Password sign-in stores a short-lived token in the signed session cookie. The
    # controller admits only account-admin and curator password identities, so a valid
    # member credential cannot open the curator UI.
    get "/sign-in", GovernanceSessionController, :new
    post "/sign-in", GovernanceSessionController, :create
    delete "/sign-out", GovernanceSessionController, :delete

    # The on_mount hook re-verifies the session token, the password identity kind, and the
    # curator/account-admin role on the initial render and again on every socket
    # (re)connect, redirecting to sign-in otherwise. Presence of the cookie alone is never
    # treated as authorization, because a token can expire or be revoked while a tab stays
    # open. This is the only place human curator decisions can be made.
    live_session :governance,
      on_mount: [{CartularyWeb.GovernanceAuth, :default}] do
      live "/", GovernanceLive.Index, :index
    end
  end

  # Subject self-governance: a person acting on knowledge about themselves. Same JSON
  # transport and bearer authentication as the memory routes, plus the human-only gate, so
  # the three pipelines must stay in this order.
  scope "/api/v1", CartularyWeb do
    pipe_through [:api, :authenticated_api, :human_governance]

    get "/self/knowledge", SelfGovernanceController, :index
    post "/self/knowledge/:id/contest", SelfGovernanceController, :contest
    post "/self/knowledge/:id/redact", SelfGovernanceController, :redact
    post "/self/erasure", SelfGovernanceController, :erase
  end

  # Model Context Protocol endpoint for agent tooling. It authenticates exactly like the
  # JSON memory routes — bearer credential in, Account derived from it — so an MCP client
  # can never reach another tenant's data.
  scope "/mcp" do
    pipe_through [:api, :authenticated_api]

    # This list is the complete machine tool surface: submit raw observations, read governed
    # memory, answer the calling peer's own pending question, and adjust that peer's own
    # interruption limits. It contains no approve, edit, reject, merge, defer, promote, or
    # gate-rule tool, and must not gain one — that would let any API key push knowledge into
    # shared scopes without a human curator, which is precisely what the gates prevent.
    #
    # "2025-03-26" is the MCP protocol revision advertised to clients during handshake;
    # changing it changes what clients believe this server speaks.
    forward "/", AshAi.Mcp.Router,
      tools: [
        :ingest,
        :get_context,
        :search,
        :ask,
        :query_knowledge,
        :check_readiness,
        :resolve_validation,
        :set_ask_preference
      ],
      protocol_version_statement: "2025-03-26",
      otp_app: :cartulary
  end
end
