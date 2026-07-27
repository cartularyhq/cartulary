# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.Router do
  use CartularyWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", CartularyWeb do
    pipe_through :api

    get "/health", MemoryController, :health

    scope "/v1" do
      post "/ingest", MemoryController, :ingest
      post "/ask", MemoryController, :ask
      post "/search", MemoryController, :search
      post "/context", MemoryController, :context
      get "/knowledge", MemoryController, :knowledge
    end
  end
end
