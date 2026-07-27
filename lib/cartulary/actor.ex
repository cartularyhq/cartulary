# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Actor do
  @moduledoc """
  Identity-derived authorization context passed to Ash actions.

  F1 introduces the action-layer Account wall. The local `poc-0` adapter still
  derives an Account key from `x-cartulary-account-key`; F3 will replace that
  adapter with real authentication without changing this domain contract.
  """

  @enforce_keys [:account_id, :account_key]
  defstruct [
    :account_id,
    :account_key,
    :peer_id,
    role: :member,
    scope_ids: :all,
    pipeline?: false
  ]

  @type role :: :account_admin | :curator | :member | :reader | :system

  @type t :: %__MODULE__{
          account_id: Ecto.UUID.t(),
          account_key: String.t(),
          peer_id: Ecto.UUID.t() | nil,
          role: role(),
          scope_ids: :all | [Ecto.UUID.t()],
          pipeline?: boolean()
        }

  def bootstrap(account_key) do
    %{account_id: nil, account_key: account_key, role: :system, scope_ids: :all, pipeline?: false}
  end

  def for_account(account, overrides \\ []) do
    struct!(
      __MODULE__,
      Keyword.merge(
        [
          account_id: account.id,
          account_key: account.key,
          role: :member,
          scope_ids: :all,
          pipeline?: false
        ],
        overrides
      )
    )
  end
end
