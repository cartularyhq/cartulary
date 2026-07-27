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
    resource Cartulary.Accounts.ApiKey
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

    create :provision_free do
      accept [:key, :name]
      upsert? true
      upsert_identity :unique_key
      upsert_fields [:name, :edition_slot, :updated_at]
      change set_attribute(:edition_slot, "community-free")
    end

    update :update do
      accept [:name]
    end
  end

  policies do
    policy action([:ensure, :provision_free]) do
      authorize_if expr(key == ^actor(:account_key))
    end

    policy action_type([:read, :update]) do
      authorize_if expr(id == ^actor(:account_id))
      authorize_if expr(key == ^actor(:account_key) and ^actor(:role) == :system)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :key, :string, allow_nil?: false, public?: true
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :edition_slot, :string
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_key, [:key]
  end
end

defmodule Cartulary.Accounts.Peer do
  @moduledoc false

  use Cartulary.Resource,
    domain: Cartulary.Accounts,
    table: "peers",
    extensions: [AshAuthentication]

  authentication do
    domain Cartulary.Accounts
    subject_name(:peer)
    session_identifier(:unsafe)

    tokens do
      enabled?(true)
      token_resource(false)
      signing_secret(Cartulary.Identity.SigningSecret)
      token_lifetime({12, :hours})
    end

    strategies do
      password :password do
        identity_field(:email)
        hashed_password_field(:hashed_password)
        registration_enabled?(true)
        sign_in_tokens_enabled?(false)
      end

      api_key :api_key do
        api_key_relationship(:valid_api_keys)
        api_key_hash_attribute(:api_key_hash)
      end
    end
  end

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

    create :register_with_password do
      accept [:key, :name, :kind, :default_scope_id]

      argument :email, :ci_string, allow_nil?: false

      argument :password, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [min_length: 8]

      argument :password_confirmation, :string, allow_nil?: false, sensitive?: true

      change set_attribute(:email, arg(:email))
      change AshAuthentication.Strategy.Password.HashPasswordChange
      change AshAuthentication.GenerateTokenChange
      validate AshAuthentication.Strategy.Password.PasswordConfirmationValidation

      metadata :token, :string, allow_nil?: false
    end

    read :sign_in_with_password do
      get? true
      argument :email, :ci_string, allow_nil?: false
      argument :password, :string, allow_nil?: false, sensitive?: true
      prepare AshAuthentication.Strategy.Password.SignInPreparation
      metadata :token, :string, allow_nil?: false
    end

    read :sign_in_with_api_key do
      argument :api_key, :string, allow_nil?: false, sensitive?: true
      prepare AshAuthentication.Strategy.ApiKey.SignInPreparation
    end

    destroy :erase do
      require_atomic? false
    end
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end

    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    policy action(:erase) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :default_scope_id, :uuid, public?: true
    attribute :key, :string, allow_nil?: false, public?: true
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :kind, :string, allow_nil?: false, default: "human", public?: true
    attribute :email, :ci_string, public?: true
    attribute :hashed_password, :string, sensitive?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_key, [:key]
    identity :unique_email, [:email]
  end

  relationships do
    has_many :valid_api_keys, Cartulary.Accounts.ApiKey do
      destination_attribute :peer_id
      filter expr(is_nil(expires_at) or expires_at > now())
    end
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
      accept [
        :peer_id,
        :provider,
        :subject,
        :email,
        :assurance,
        :linked_at,
        :active,
        :metadata
      ]
    end

    update :update do
      accept [:email, :assurance, :active, :metadata]
    end

    destroy :erase do
      require_atomic? false
    end
  end

  policies do
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if {Cartulary.Policy.RoleIn, roles: [:account_admin, :system]}
    end

    policy action(:erase) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :peer_id, :uuid, allow_nil?: false, public?: true
    attribute :provider, :string, allow_nil?: false, public?: true
    attribute :subject, :string, allow_nil?: false, public?: true
    attribute :email, :string, public?: true
    attribute :assurance, :string, allow_nil?: false, default: "medium", public?: true
    attribute :linked_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :active, :boolean, allow_nil?: false, default: true, public?: true
    attribute :metadata, :map, allow_nil?: false, default: %{}
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :provider_subject, [:provider, :subject]
  end
end

defmodule Cartulary.Accounts.ApiKey do
  @moduledoc false

  use Cartulary.Resource, domain: Cartulary.Accounts, table: "api_keys"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:destroy]

    read :read do
      primary? true
      multitenancy :allow_global
    end

    create :create do
      primary? true
      accept [:account_id, :peer_id, :scope_id, :expires_at]

      change {AshAuthentication.Strategy.ApiKey.GenerateApiKey,
              prefix: :cartulary, hash: :api_key_hash}
    end
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end

    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    policy action_type([:create, :destroy]) do
      authorize_if {Cartulary.Policy.RoleIn, roles: [:account_admin, :system]}
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :peer_id, :uuid, allow_nil?: false, public?: true
    attribute :scope_id, :uuid, public?: true
    attribute :api_key_hash, :binary, allow_nil?: false, sensitive?: true
    attribute :expires_at, :utc_datetime_usec, public?: true
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :peer, Cartulary.Accounts.Peer do
      source_attribute :peer_id
      destination_attribute :id
      allow_nil? false
    end

    belongs_to :account, Cartulary.Accounts.Account do
      source_attribute :account_id
      destination_attribute :id
      allow_nil? false
    end
  end

  identities do
    identity :unique_api_key, [:api_key_hash]
  end
end
