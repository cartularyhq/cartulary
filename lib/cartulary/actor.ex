# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Actor do
  @moduledoc """
  The authorization context that every Ash action in Cartulary runs under.

  An actor answers three questions for the authorizer: which Account the caller
  belongs to, which scopes inside that Account the caller may touch, and what
  the caller may do there. Ash policies reach those answers either through
  expressions such as `actor(:account_id)` and `actor(:peer_id)` or through the
  check modules in `Cartulary.Resource` (`Cartulary.Policy.ScopeAccess`,
  `Cartulary.Policy.RoleIn`, `Cartulary.Policy.HumanRoleIn`, and friends), which
  read these fields directly. `Cartulary.DataLayer` separately mirrors
  `account_id` into the transaction-local PostgreSQL setting that row-level
  security compares against.

  ## The Account is derived, never requested

  `account_id` and `account_key` come from a verified credential — a signed
  session token or an API key whose hash matched a stored row. They are never
  taken from a request header, query string, or body. Building an actor from
  caller-supplied Account data would collapse the isolation wall between
  Accounts, so any new construction path must start from an authenticated
  identity or from an explicitly internal bootstrap helper.

  ## Field meanings

  - `peer_id` — the authenticated Peer. `nil` for internal/system actors that
    act on behalf of the Account rather than a person or agent.
  - `identity_kind` — how the caller proved who they are: `:password` for a
    session token, `:api_key` for a machine credential, `:system` for internal
    work that bypassed authentication because it never left the server.
  - `assurance` — how strongly that identity is trusted, copied from the linked
    external identity record and carried through role re-resolution. Nothing in
    the current codebase branches on it; it is recorded, not yet enforced.
  - `credential_scope_id` — set when the presented API key was restricted to a
    single scope subtree. Role resolution intersects the caller's granted
    scopes with that subtree, so a restricted key can only ever narrow access.
  - `role` — the highest effective role across all authorized scopes. Coarse
    checks use it; anything scope-sensitive should consult `scope_roles`.
  - `scope_ids` — the concrete scopes this actor may read. `:all` means
    unrestricted within the Account and is reserved for internal/system actors;
    an authenticated caller always carries an explicit list, and an empty list
    means no scope access at all.
  - `scope_roles` — per-scope effective role. A scope missing from this map is
    not authorized, either because no grant applies or because a deny does.
  - `pipeline?` — true only for the internal knowledge pipeline. Several
    resources expose erase/rebuild actions that check this flag, so never set
    it on an actor derived from an external request.

  ## Mistakes to avoid

  Do not hand-edit `role`, `scope_ids`, or `scope_roles` on an actor that came
  from authentication in order to widen access; re-resolve it from the Peer's
  role grants instead. Do not cache an actor across a role change without
  re-resolving — grants are evaluated at authentication time, not per query.
  """

  @enforce_keys [:account_id, :account_key]
  defstruct [
    :account_id,
    :account_key,
    :peer_id,
    :identity_id,
    :identity_kind,
    :assurance,
    :credential_scope_id,
    role: :member,
    scope_ids: :all,
    scope_roles: %{},
    pipeline?: false
  ]

  @typedoc """
  Effective authorization role.

  `:reader`, `:member`, `:curator`, and `:account_admin` are the four roles a
  human or agent can be granted, in increasing order of power. `:system` is not
  grantable: it marks internal server-side work and is checked separately by
  policies, so it deliberately has no place in the grant ranking.
  """
  @type role :: :account_admin | :curator | :member | :reader | :system

  @type t :: %__MODULE__{
          account_id: Ecto.UUID.t(),
          account_key: String.t(),
          peer_id: Ecto.UUID.t() | nil,
          identity_id: Ecto.UUID.t() | nil,
          identity_kind: :password | :api_key | :system | nil,
          assurance: :low | :medium | :high | nil,
          credential_scope_id: Ecto.UUID.t() | nil,
          role: role(),
          scope_ids: :all | [Ecto.UUID.t()],
          scope_roles: %{optional(Ecto.UUID.t()) => role()},
          pipeline?: boolean()
        }

  @doc """
  Builds the throwaway actor used to look up or create an Account by key.

  This is the chicken-and-egg case: the Account row is not known yet, so there
  is no `account_id` to authorize against. It returns a plain map rather than a
  `%Cartulary.Actor{}`, since every field of the struct is meant to name a
  resolved Account. Both Account policies that this map can satisfy match on
  `key == actor(:account_key)`, and the surrounding transaction has already
  pinned the same key into the transaction-local PostgreSQL setting that
  row-level security reads, so the map cannot see rows belonging to any other
  Account.

  Use it only from the infrastructure layer that opens Account transactions.
  Passing it to domain actions would grant `:system` privileges with no
  resolved Account behind them.
  """
  def bootstrap(account_key) do
    %{
      account_id: nil,
      account_key: account_key,
      identity_kind: :system,
      assurance: :high,
      role: :system,
      scope_ids: :all,
      scope_roles: %{},
      pipeline?: false
    }
  end

  @doc """
  Builds an internal actor bound to an already-resolved Account record.

  `account` must be a loaded Account (its `id` and `key` are copied verbatim).
  `overrides` is a keyword list merged over the defaults, and is how callers ask
  for `role: :system`, a restricted `scope_ids` list, or `pipeline?: true`.

  The defaults are deliberately unauthenticated-looking: `identity_kind:
  :system`, no `peer_id`, `role: :member`, and `scope_ids: :all`. That means the
  result already sees every scope in the Account, so this is an internal
  helper — infrastructure transactions, the pipeline, migrations, and tests. It
  is not a substitute for resolving a real caller's grants. An actor for someone
  who authenticated over HTTP must come from role resolution against their Peer,
  otherwise scope restrictions and deny grants are silently skipped.

  Raises `KeyError` when `overrides` names a field the struct does not have, and
  raises whatever `account.id` or `account.key` raises when `account` is not a
  record carrying both.
  """
  def for_account(account, overrides \\ []) do
    struct!(
      __MODULE__,
      Keyword.merge(
        [
          account_id: account.id,
          account_key: account.key,
          identity_kind: :system,
          assurance: :high,
          role: :member,
          scope_ids: :all,
          scope_roles: %{},
          pipeline?: false
        ],
        overrides
      )
    )
  end
end
