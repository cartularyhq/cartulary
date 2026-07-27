# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.Router do
  use CartularyWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :authenticated_api do
    plug CartularyWeb.Plugs.RequireIdentity
  end

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

  pipeline :human_governance do
    plug CartularyWeb.Plugs.RequireHumanIdentity
  end

  scope "/api", CartularyWeb do
    pipe_through :api

    get "/health", MemoryController, :health
    post "/auth/password", AuthController, :password

    scope "/v1" do
      pipe_through :authenticated_api

      post "/ingest", MemoryController, :ingest
      post "/ask", MemoryController, :ask
      post "/search", MemoryController, :search
      post "/context", MemoryController, :context
      get "/knowledge", MemoryController, :knowledge
    end
  end

  scope "/governance", CartularyWeb do
    pipe_through :browser

    get "/sign-in", GovernanceSessionController, :new
    post "/sign-in", GovernanceSessionController, :create
    delete "/sign-out", GovernanceSessionController, :delete

    live_session :governance,
      on_mount: [{CartularyWeb.GovernanceAuth, :default}] do
      live "/", GovernanceLive.Index, :index
    end
  end

  scope "/api/v1", CartularyWeb do
    pipe_through [:api, :authenticated_api, :human_governance]

    get "/self/knowledge", SelfGovernanceController, :index
    post "/self/knowledge/:id/contest", SelfGovernanceController, :contest
    post "/self/knowledge/:id/redact", SelfGovernanceController, :redact
    post "/self/erasure", SelfGovernanceController, :erase
  end

  scope "/mcp" do
    pipe_through [:api, :authenticated_api]

    forward "/", AshAi.Mcp.Router,
      tools: [
        :ingest,
        :get_context,
        :search,
        :ask,
        :query_knowledge,
        :resolve_validation,
        :set_ask_preference
      ],
      protocol_version_statement: "2025-03-26",
      otp_app: :cartulary
  end
end
