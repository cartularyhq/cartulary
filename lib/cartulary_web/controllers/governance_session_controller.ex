# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.GovernanceSessionController do
  use CartularyWeb, :controller

  alias Cartulary.Identity

  def new(conn, params) do
    render(conn, :new,
      invalid_credentials?: params["error"] == "invalid",
      csrf_token: Plug.CSRFProtection.get_csrf_token()
    )
  end

  def create(conn, %{"email" => email, "password" => password}) do
    case Identity.sign_in_password(email, password) do
      {:ok, %{actor: actor, token: token}}
      when actor.role in [:account_admin, :curator] and actor.identity_kind == :password ->
        conn
        |> put_session(:governance_token, token)
        |> configure_session(renew: true)
        |> redirect(to: "/governance")

      _other ->
        redirect(conn, to: "/governance/sign-in?error=invalid")
    end
  end

  def delete(conn, _params) do
    conn
    |> clear_session()
    |> redirect(to: "/governance/sign-in")
  end
end
