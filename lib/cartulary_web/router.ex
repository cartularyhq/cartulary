# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.Router do
  use CartularyWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :authenticated_api do
    plug CartularyWeb.Plugs.RequireIdentity
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
end
