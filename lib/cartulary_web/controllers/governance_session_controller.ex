# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.GovernanceSessionController do
  @moduledoc """
  Opens and closes the browser session that the human curator interface runs on.

  Curator authority — approving, editing, rejecting, merging, deferring, promoting, and
  administering gate rules — exists only behind this session. This controller is therefore
  the door, and it is deliberately narrow:

  - sign-in is by email and password only, so a machine API key has nothing to present
    here; there is no header, token, or parameter that substitutes for the form;
  - the authenticated identity must have come from a password sign-in *and* hold the
    curator or account-admin role. A valid member or reader credential is turned away just
    like a bad password;
  - holding the session cookie is never treated as proof on its own. The live interface
    re-verifies the stored token, the identity kind, and the role on every mount and
    reconnect, so a role change or an expired token ends the session at the next render.

  Every rejection — wrong password, unknown email, machine credential, insufficient role —
  produces the same redirect back to the form. The failure reason is never disclosed,
  because distinguishing "no such user" from "not a curator" would leak who the curators
  are.
  """

  use CartularyWeb, :controller

  alias Cartulary.Identity

  @doc """
  Renders the curator sign-in form.

  Reads one optional query parameter, `error`. The value `"invalid"` — the only value the
  failure path ever sets — turns on a generic "invalid credentials" notice. The reason is
  carried in the URL rather than in a flash because the failing request answers with a
  redirect and keeps no session.

  A CSRF token is passed into the template because the form posts back through a route
  that rejects unverified requests; without it, sign-in cannot succeed.
  """
  def new(conn, params) do
    render(conn, :new,
      invalid_credentials?: params["error"] == "invalid",
      csrf_token: Plug.CSRFProtection.get_csrf_token()
    )
  end

  @doc """
  Authenticates the form and, on success, establishes the curator session.

  Accepts `email` and `password` from the posted form. A request missing either field
  matches no clause and is refused as a bad request rather than being treated as a failed
  sign-in.

  Success requires all three of: valid credentials, an identity that came from a password
  sign-in, and the curator or account-admin role. Only then is the session token stored
  under the session and the caller sent to the governance interface. The session id is
  regenerated at the same moment, so a session identifier planted in the browser before
  sign-in cannot be reused afterwards.

  Anything else — bad credentials, a non-password identity, or a member/reader role — falls
  through to the same redirect back to the sign-in page carrying the generic invalid
  marker. Keep that single catch-all: splitting it into specific messages would tell an
  attacker which of the three conditions they failed.
  """
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

  @doc """
  Signs the curator out and returns them to the form.

  Drops the whole session rather than just the stored token, so nothing survives that a
  later request could act on.

  This removes the browser's copy of the credential; it does not revoke it. Session tokens
  are stateless and stay valid on their signature until they expire, so a token that has
  already been copied elsewhere is unaffected by signing out. Expiry, not this action, is
  what bounds a leaked token.
  """
  def delete(conn, _params) do
    conn
    |> clear_session()
    |> redirect(to: "/governance/sign-in")
  end
end
