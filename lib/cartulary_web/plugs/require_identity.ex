# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.Plugs.RequireIdentity do
  @moduledoc false

  @behaviour Plug

  import Plug.Conn

  alias Cartulary.Identity

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with ["Bearer " <> credential] <- get_req_header(conn, "authorization"),
         {:ok, actor} <- Identity.authenticate_bearer(credential) do
      assign(conn, :current_actor, actor)
    else
      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: "Unauthorized"}))
        |> halt()
    end
  end
end
