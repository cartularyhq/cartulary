# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Actor do
  @moduledoc """
  Identity-derived authorization context passed to Ash actions.

  F3 resolves this context from an authenticated Peer and its inherited role
  grants. Legacy internal/eval callers may still construct a system-scoped
  actor through `Cartulary.DataLayer`, but HTTP request data never selects the
  Account.
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
