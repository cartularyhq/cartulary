# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.AuthController do
  @moduledoc """
  Exchanges a human's email and password for the bearer token the JSON API expects.

  This is the only unauthenticated route that produces a credential, and it produces
  exactly one kind: a token for a *person*. Agent API keys are not minted here — they are
  provisioned out of band by an account administrator — so no amount of calling this
  endpoint can create a machine identity.

  The token it returns authenticates the memory routes and, because it was created by a
  password sign-in, also the human-only self-governance routes. It does not by itself open
  the curator browser UI: that runs on a separate cookie session which is established by
  its own sign-in form and additionally requires a curator or account-admin role.

  Tokens are stateless and are trusted on their signature alone, with no server-side
  session record, so an issued token cannot be revoked before it expires. Its configured
  12-hour lifetime is therefore the real bound on a leaked credential. Treat the response
  body as a secret: never log it, and never write it into an audit entry or a trace
  attribute.
  """

  use CartularyWeb, :controller

  alias Cartulary.Identity

  @doc """
  Signs a human in with email and password.

  On success answers 200 with `%{"data" => %{"token" => ..., "token_type" => "Bearer",
  "peer_id" => ...}}`. Send the token back as `Authorization: Bearer <token>`.

  Every failure answers 401 with the same opaque `%{"error" => "Unauthorized"}` body: an
  unknown email, a wrong password, a peer outside this deployment's Account, and a request
  missing or mistyping the fields are all indistinguishable. That uniformity is the point
  — a more helpful message would let an attacker enumerate which accounts exist. The
  second clause is what catches the malformed-body case, so it must keep answering exactly
  like the first.

  The Account is not a parameter. It is resolved from the deployment's single community
  Account during sign-in, and a signed subject that does not belong to it is rejected.
  """
  def password(conn, %{"email" => email, "password" => password}) do
    case Identity.sign_in_password(email, password) do
      {:ok, %{peer: peer, token: token}} ->
        json(conn, %{data: %{token: token, token_type: "Bearer", peer_id: peer.id}})

      {:error, :unauthorized} ->
        unauthorized(conn)
    end
  end

  def password(conn, _params), do: unauthorized(conn)

  # The single rejection response. Both the credential-mismatch path and the
  # malformed-request path funnel through here so they stay byte-identical; giving either
  # one its own message would turn this endpoint into an account oracle.
  defp unauthorized(conn) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: "Unauthorized"})
  end
end
