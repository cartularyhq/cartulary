# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.ConsoleAuth do
  @moduledoc """
  Mount-time authentication for the browser console at `/console`.

  The console is the reading surface: a signed-in person explores the memory
  their role grants reach, and acts on the parts they are entitled to act on.
  Unlike the curator queue, it admits **any** human role — reader, member,
  curator, account admin — because seeing what a system has recorded about you
  and your scopes is not a privileged operation. What differs between roles is
  what the pages then show and offer, which
  `CartularyWeb.Console.Access` decides.

  Two conditions must hold before a socket may mount:

  1. the sign-in token stored in the browser session still authenticates; and
  2. the resulting identity is a password sign-in by a person, not a machine
     API key.

  The second is not a formality. An agent credential must never drive a browser
  session, because the console offers subject gestures — contest, redact,
  request erasure — that only a person may take on their own behalf. A rejected
  mount redirects to the sign-in page without saying which condition failed.

  ## Why the check is repeated on every mount

  A LiveView mounts twice: once during the initial HTTP render, and again when
  the browser opens its WebSocket. The socket connection does not pass through
  the router's plug pipelines, so plug-based authentication cannot cover it.
  The token therefore lives in the signed session cookie, put there by the
  sign-in controller, and is re-verified here each time. Remove that and the
  live socket runs unauthenticated behind a correct-looking first render.

  ## Freshness

  The actor — including its effective role and its authorized scope list — is
  resolved from the credential at each mount rather than carried across. A
  revoked grant therefore takes effect on the next mount or reconnect. A socket
  that is already open keeps the actor it resolved, so a long-lived tab is not
  re-checked until it reconnects.

  ## Relationship to the curator hook

  `CartularyWeb.GovernanceAuth` guards `/governance` and additionally demands
  the curator or account-admin role. Both hooks read the same session key, so
  one sign-in opens both surfaces and a curator moving between them is not
  asked to authenticate twice. Keep the key identical in both, or signing in at
  one door will silently fail to open the other.

  ## Mistakes to avoid

  The actor must be established here and nowhere else. Do not let an event
  handler replace `socket.assigns.current_actor`, and do not build an actor
  from mount params, query strings, or anything else the client controls —
  every page reads that assign as its authorization context, and every Ash
  query in the console is run as it.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [redirect: 2]

  alias Cartulary.Identity

  @doc """
  LiveView `on_mount` hook wired into the console live session.

  Returns `{:cont, socket}` with `current_actor` assigned when the session's
  sign-in token belongs to a person, and `{:halt, socket}` redirecting to
  `/sign-in` in every other case, including a session carrying no token.
  """
  def on_mount(:default, _params, %{"governance_token" => token}, socket) do
    with {:ok, actor} <- Identity.authenticate_bearer(token),
         true <- actor.identity_kind == :password do
      {:cont, assign(socket, :current_actor, actor)}
    else
      # An expired token, a machine credential, and an unknown credential all
      # end identically on purpose: a distinguishable failure would tell an
      # unauthenticated visitor which part of their guess was right.
      _other -> {:halt, redirect(socket, to: "/sign-in")}
    end
  end

  # Reached when the session holds no sign-in token: signed out, session
  # expired, or the console was opened directly. Fails closed like every other
  # rejection above.
  def on_mount(:default, _params, _session, socket),
    do: {:halt, redirect(socket, to: "/sign-in")}
end
