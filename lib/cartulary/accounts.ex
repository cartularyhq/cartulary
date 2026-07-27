# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Accounts do
  @moduledoc """
  Ash domain for the Account isolation boundary and external identities.

  Implements the F1 backbone for `FR-TOP-1`, `FR-TOP-2`, `AINV-6`, and
  `AD-SEC-1`.
  """

  use Ash.Domain

  resources do
    resource Cartulary.Accounts.Account
    resource Cartulary.Accounts.Peer
    resource Cartulary.Accounts.ExternalIdentity
  end
end

defmodule Cartulary.Accounts.Account do
  @moduledoc false

  use Cartulary.Resource, domain: Cartulary.Accounts, table: "accounts"

  actions do
    read :read do
      primary? true
    end

    create :ensure do
      accept [:key, :name]
      upsert? true
      upsert_identity :unique_key
      upsert_fields [:name, :updated_at]
    end

    update :update do
      accept [:name]
    end
  end

  policies do
    policy action(:ensure) do
      authorize_if expr(key == ^actor(:account_key))
    end

    policy action_type([:read, :update]) do
      authorize_if expr(id == ^actor(:account_id))
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :key, :string, allow_nil?: false, public?: true
    attribute :name, :string, allow_nil?: false, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_key, [:key]
  end
end

defmodule Cartulary.Accounts.Peer do
  @moduledoc false

  use Cartulary.Resource, domain: Cartulary.Accounts, table: "peers"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    read :read do
      primary? true
    end

    create :ensure do
      accept [:key, :name, :kind, :default_scope_id]
      upsert? true
      upsert_identity :unique_key
      upsert_fields [:name, :kind, :default_scope_id, :updated_at]
    end

    update :update do
      accept [:name, :kind, :default_scope_id]
    end
  end

  policies do
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :default_scope_id, :uuid, public?: true
    attribute :key, :string, allow_nil?: false, public?: true
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :kind, :string, allow_nil?: false, default: "human", public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_key, [:key]
  end
end

defmodule Cartulary.Accounts.ExternalIdentity do
  @moduledoc false

  use Cartulary.Resource, domain: Cartulary.Accounts, table: "external_identities"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    create :create do
      accept [:peer_id, :provider, :subject, :email, :metadata]
    end

    update :update do
      accept [:email, :metadata]
    end
  end

  policies do
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :peer_id, :uuid, allow_nil?: false, public?: true
    attribute :provider, :string, allow_nil?: false, public?: true
    attribute :subject, :string, allow_nil?: false, public?: true
    attribute :email, :string, public?: true
    attribute :metadata, :map, allow_nil?: false, default: %{}
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :provider_subject, [:provider, :subject]
  end
end
