# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Retrieval do
  @moduledoc "Ash domain for named, versioned retrieval profiles (`AD-SEAM-3`)."

  use Ash.Domain

  resources do
    resource Cartulary.Retrieval.RetrievalProfile
  end
end

defmodule Cartulary.Retrieval.RetrievalProfile do
  @moduledoc false

  use Cartulary.Resource,
    domain: Cartulary.Retrieval,
    table: "retrieval_profiles"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    create :create do
      accept [:scope_id, :name, :version, :strategy_config, :deadline_ms, :active]
    end

    update :update do
      accept [:strategy_config, :deadline_ms, :active]
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
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :version, :integer, allow_nil?: false, public?: true
    attribute :strategy_config, :map, allow_nil?: false, default: %{}
    attribute :deadline_ms, :integer, allow_nil?: false, public?: true
    attribute :active, :boolean, allow_nil?: false, default: true, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :scope_name_version, [:scope_id, :name, :version]
  end
end
