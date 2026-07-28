# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.Plugs.RequireIdentity do
  @moduledoc """
  Turns an HTTP `Authorization: Bearer ...` credential into the authorization
  context that every downstream Ash action runs under.

  This plug is the only place where an HTTP request acquires an Account. The
  bearer credential is either a signed human sign-in token or a machine API
  key; both resolve, through `Cartulary.Identity`, to a `Cartulary.Actor` whose
  Account, Peer, effective role, and authorized scopes come from the verified
  credential.

  ## The Account is derived from the credential, never requested

  Cross-Account isolation depends on the caller being unable to name the
  Account it wants. Nothing in the request path, query string, headers, or body
  may influence which Account is selected — an earlier design used an
  `x-cartulary-account-key` request header and that header is now inert.
  Anything added here that reads Account identity out of the request would
  collapse the isolation wall, so this plug must keep deriving it solely from
  the authenticated credential.

  ## What it installs on the connection

  - `conn.assigns.current_actor` — read by controllers and by the usage
    metering plug.
  - the Ash actor — what policies evaluate.
  - the Ash tenant, set to the Account id — every Account-scoped resource uses
    attribute multitenancy on `account_id`, so this is what filters reads and
    stamps writes. The second wall, the transaction-local PostgreSQL setting
    that row-level security compares against, is installed separately by the
    Account-scoped transaction helper the domain calls, not here.
  - the Ash context key `cartulary_actor` — carries the originating human or
    agent identity into changes that run under an elevated internal actor and
    still need to record who caused the write.

  ## Failure behaviour

  Every failure — no `Authorization` header, a header that is not a single
  `Bearer` value, an unparseable credential, an unknown or revoked credential,
  or a credential belonging to another Account — produces the same opaque
  `401` JSON body and halts the pipeline. The uniformity is deliberate:
  distinguishing "no such key" from "wrong Account" would let an attacker probe
  for valid credentials. Do not add a more specific error message or status
  here.

  Because this plug halts, any plug placed after it in the same pipeline runs
  only for authenticated requests.
  """

  @behaviour Plug

  import Plug.Conn

  alias Cartulary.Identity

  @doc """
  Plug callback. Options are unused; whatever is passed is returned unchanged.
  """
  @impl true
  def init(opts), do: opts

  @doc """
  Authenticates the bearer credential and installs the actor, tenant, and Ash
  context, or halts the connection with an opaque `401`.

  Returns the connection either way; callers downstream may assume
  `conn.assigns.current_actor` is present because the unauthenticated branch
  halts.
  """
  @impl true
  def call(conn, _opts) do
    # A single "Bearer <credential>" header is the only accepted shape. Repeated
    # or differently framed Authorization headers fall through to the 401 branch
    # rather than being merged, so a smuggled second header cannot win.
    with ["Bearer " <> credential] <- get_req_header(conn, "authorization"),
         {:ok, actor} <- Identity.authenticate_bearer(credential) do
      conn
      |> assign(:current_actor, actor)
      |> Ash.PlugHelpers.set_actor(actor)
      |> Ash.PlugHelpers.set_tenant(actor.account_id)
      |> Ash.PlugHelpers.set_context(%{cartulary_actor: actor})
    else
      # One indistinguishable rejection for every authentication failure mode,
      # and no echo of the presented credential into the response or logs.
      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: "Unauthorized"}))
        |> halt()
    end
  end
end
