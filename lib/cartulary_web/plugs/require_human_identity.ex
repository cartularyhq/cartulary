# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.Plugs.RequireHumanIdentity do
  @moduledoc false

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{assigns: %{current_actor: %{identity_kind: :password}}} = conn, _opts),
    do: conn

  def call(conn, _opts) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(403, Jason.encode!(%{error: "Human identity required"}))
    |> halt()
  end
end
