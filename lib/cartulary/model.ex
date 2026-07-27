# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Model do
  @moduledoc "Ash domain for provider-neutral, versioned model-role configuration."

  use Ash.Domain

  resources do
    resource Cartulary.Model.ModelRoleConfig
  end
end

defmodule Cartulary.Model.ModelRoleConfig do
  @moduledoc false

  use Cartulary.Resource, domain: Cartulary.Model, table: "model_role_configs"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    create :create do
      accept [:scope_id, :role, :provider, :model, :options, :version, :active]
    end

    update :update do
      accept [:provider, :model, :options, :version, :active]
    end
  end

  policies do
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if {Cartulary.Policy.RoleIn, roles: [:account_admin, :system]}
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :scope_id, :uuid
    attribute :role, :string, allow_nil?: false, public?: true
    attribute :provider, :string, allow_nil?: false, public?: true
    attribute :model, :string, allow_nil?: false, public?: true
    attribute :options, :map, allow_nil?: false, default: %{}
    attribute :version, :integer, allow_nil?: false, default: 1, public?: true
    attribute :active, :boolean, allow_nil?: false, default: true, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :scope_role_version, [:scope_id, :role, :version]
  end
end
