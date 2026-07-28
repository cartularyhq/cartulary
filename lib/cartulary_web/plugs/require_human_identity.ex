# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.Plugs.RequireHumanIdentity do
  @moduledoc """
  Restricts a route to a caller who signed in as a person, rejecting machine
  credentials.

  Cartulary distinguishes two kinds of authenticated identity: a human who
  authenticated with a password (`:password`) and an agent presenting a
  long-lived API key (`:api_key`). Machine credentials are allowed to submit
  raw observations, read governed memory, and answer questions addressed to
  their own peer. They must never exercise the decisions that only a person may
  make — approving, editing, rejecting, merging or deferring proposed
  knowledge, administering gate rules, running bulk curator actions, or
  exercising a data subject's own rights to contest, redact, or request
  erasure. This plug is the HTTP-side enforcement of that split.

  ## Ordering requirement

  It reads `conn.assigns.current_actor` and therefore must run after the plug
  that authenticates the bearer credential. It deliberately fails closed: if
  the actor assign is missing — because the pipelines were reordered, or the
  route was attached without authentication — the request is rejected rather
  than allowed through unchecked.

  ## What it does not check

  Only the *kind* of identity. It says nothing about roles or scopes. A signed-in
  reader passes this plug; whether that person may act on a particular piece of
  knowledge is decided by the governance domain and by Ash policies, not here.
  Do not treat passing this plug as authorization.
  """

  @behaviour Plug

  import Plug.Conn

  @doc """
  Plug callback. Options are unused; whatever is passed is returned unchanged.
  """
  @impl true
  def init(opts), do: opts

  @doc """
  Allows the request through unchanged for a password-authenticated human, and
  otherwise halts it with a `403` JSON body.

  The rejecting clause also covers the case where no actor was assigned at all,
  which is why the match on the human case is written as a head pattern rather
  than a conditional inside one clause.
  """
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
