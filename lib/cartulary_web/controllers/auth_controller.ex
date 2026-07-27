# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.AuthController do
  use CartularyWeb, :controller

  alias Cartulary.Identity

  def password(conn, %{"email" => email, "password" => password}) do
    case Identity.sign_in_password(email, password) do
      {:ok, %{peer: peer, token: token}} ->
        json(conn, %{data: %{token: token, token_type: "Bearer", peer_id: peer.id}})

      {:error, :unauthorized} ->
        unauthorized(conn)
    end
  end

  def password(conn, _params), do: unauthorized(conn)

  defp unauthorized(conn) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: "Unauthorized"})
  end
end
