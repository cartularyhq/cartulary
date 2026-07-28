# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.GovernanceAuth do
  @moduledoc """
  Mount-time authentication and authorization for the curator governance
  console LiveView.

  The governance console is where a person approves, edits, rejects, merges, or
  defers proposed knowledge. Those decisions are human-only and privileged, so
  a socket may not mount unless three things hold at once:

  1. the sign-in token stored in the browser session still authenticates;
  2. the resulting identity is a password sign-in by a person, not a machine
     API key — an agent credential must never be able to drive a curator
     decision, even if one were pasted into a session; and
  3. that person holds the account-admin or curator role.

  Anything else halts the mount and redirects to the sign-in page, with no
  indication of which check failed.

  ## Why authentication is repeated here

  A LiveView mounts twice: once during the initial HTTP render, and again when
  the browser opens the WebSocket. The WebSocket connection does not travel
  through the HTTP router pipelines, so plug-based authentication cannot cover
  it. The signed token is therefore kept in the browser session — placed there
  by the sign-in controller — and re-verified on every mount. Removing that
  re-verification would leave the live socket unauthenticated while the initial
  page render looked correct.

  ## Freshness and caching

  The actor, including its effective role and authorized scopes, is resolved
  from the credential at each mount rather than carried over. A revoked role
  grant therefore takes effect the next time the console mounts. A socket that
  is already mounted keeps the actor it resolved, so a long-lived open tab is
  not re-checked until it reconnects.

  ## Mistakes to avoid

  The actor must be established here and nowhere else. Do not let an event
  handler replace `socket.assigns.current_actor`, and do not build an actor
  from mount params or from anything else the client controls — the console's
  privileged actions read that assign as their authorization context.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [redirect: 2]

  alias Cartulary.Identity

  @doc """
  LiveView `on_mount` hook wired into the governance live session.

  Returns `{:cont, socket}` with `current_actor` assigned when the session's
  sign-in token belongs to a human curator or account admin, and
  `{:halt, socket}` redirecting to the sign-in page in every other case,
  including a session that carries no token at all.
  """
  def on_mount(:default, _params, %{"governance_token" => token}, socket) do
    with {:ok, actor} <- Identity.authenticate_bearer(token),
         true <- actor.identity_kind == :password,
         true <- actor.role in [:account_admin, :curator] do
      {:cont, assign(socket, :current_actor, actor)}
    else
      # Expired token, machine credential, insufficient role, and unknown
      # credential all end the same way on purpose: a distinguishable failure
      # would tell an unauthenticated visitor which part they got right.
      _other -> {:halt, redirect(socket, to: "/governance/sign-in")}
    end
  end

  # Reached when the browser session holds no sign-in token: signed out, session
  # expired, or the console was opened directly. Fails closed like every other
  # rejection above.
  def on_mount(:default, _params, _session, socket),
    do: {:halt, redirect(socket, to: "/governance/sign-in")}
end
