# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.SessionController do
  @moduledoc """
  Opens and closes the browser session the console runs on.

  This is the main door for people. It admits any human who can present a valid
  email and password — reader, member, curator, or account admin — because
  reading the memory your grants reach is not a privileged act. What differs
  between roles is what the console then shows and offers.

  Two things it will not do, both deliberately:

  - **It accepts no machine credential.** There is no header, token, or
    parameter that substitutes for the form. An agent API key has nothing it
    can present here, which is what keeps agents out of the browser surface and
    out of the subject gestures the console offers.
  - **It never says why an attempt failed.** A wrong password, an unknown
    address, and a credential that is not a password identity all produce the
    same redirect. Distinguishing them would let a visitor enumerate who has an
    account.

  Holding the session cookie is never treated as proof on its own. Every
  console LiveView re-verifies the stored token and the identity kind on each
  mount and each socket reconnect, so an expired or revoked credential ends the
  session at the next render rather than whenever the cookie happens to lapse.

  ## Relationship to the curator sign-in

  `CartularyWeb.GovernanceSessionController` guards the curator queue and
  additionally requires the curator or account-admin role. Both write the same
  session key, so signing in here also opens the queue for someone who holds
  that role, and a curator is not asked to authenticate twice. Keep the key
  identical in both controllers.
  """

  use CartularyWeb, :controller

  alias Cartulary.Identity

  @doc """
  Sends a visitor arriving at the bare origin to the console.

  The redirect is unconditional and carries no session check of its own: the
  console's own mount hook decides whether the visitor is signed in, and sends
  them to the form if not. Deciding it here as well would mean two places could
  disagree about what "signed in" means.
  """
  def home(conn, _params), do: redirect(conn, to: "/console")

  @doc """
  Renders the console sign-in form.

  Reads one optional query parameter, `error`. The value `"invalid"` — the only
  value the failure path ever sets — turns on a generic rejection notice. The
  reason travels in the URL rather than in a flash because the failing request
  answers with a redirect and keeps no session.

  A CSRF token is passed to the template because the POST route rejects an
  unverified request; without the field, sign-in cannot succeed at all.
  """
  def new(conn, params) do
    render(conn, :new,
      invalid_credentials?: params["error"] == "invalid",
      csrf_token: Plug.CSRFProtection.get_csrf_token()
    )
  end

  @doc """
  Authenticates the form and, on success, establishes the console session.

  Accepts `email` and `password`. A request missing either matches no clause
  and is refused as a bad request rather than being counted as a failed
  sign-in.

  Success requires valid credentials and an identity that came from a password
  sign-in. The token is then stored in the session and the session id is
  regenerated at the same moment, so an identifier planted in the browser
  before sign-in cannot be reused afterwards.

  Everything else falls through to one redirect carrying the generic invalid
  marker. Keep that single catch-all: splitting it into specific messages would
  tell a visitor which half of their guess was right.
  """
  def create(conn, %{"email" => email, "password" => password}) do
    case Identity.sign_in_password(email, password) do
      {:ok, %{actor: actor, token: token}} when actor.identity_kind == :password ->
        conn
        |> put_session(:governance_token, token)
        |> configure_session(renew: true)
        |> redirect(to: "/console")

      _other ->
        redirect(conn, to: "/sign-in?error=invalid")
    end
  end

  @doc """
  Signs the reader out and returns them to the form.

  Drops the whole session rather than only the stored token, so nothing
  survives that a later request could act on.

  This removes the browser's copy of the credential; it does not revoke it.
  Session tokens are stateless and remain valid on their signature until they
  expire, so a token already copied elsewhere is unaffected. Expiry, not this
  action, is what bounds a leaked token.
  """
  def delete(conn, _params) do
    conn
    |> clear_session()
    |> redirect(to: "/sign-in")
  end
end
