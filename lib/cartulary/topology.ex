# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Topology do
  @moduledoc """
  Ash domain for containment, cross-scope relations, and inherited role grants.

  Implements the F1 resource boundary for `FR-TOP-3` through `FR-TOP-11` and
  `AD-DATA-4`.
  """

  use Ash.Domain

  resources do
    resource Cartulary.Topology.Scope
    resource Cartulary.Topology.ScopeRelation
    resource Cartulary.Topology.RoleGrant
  end
end

defmodule Cartulary.Topology.Scope do
  @moduledoc false

  use Cartulary.Resource, domain: Cartulary.Topology, table: "scopes"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    read :read do
      primary? true
    end

    create :ensure do
      accept [:parent_id, :key, :name, :path, :state]
      upsert? true
      upsert_identity :unique_path
      upsert_fields [:name, :state, :updated_at]
    end

    update :update do
      accept [:name, :state]
    end
  end

  policies do
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    policy action_type(:read) do
      authorize_if {Cartulary.Policy.ScopeAccess, attribute: :id}
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :parent_id, :uuid, public?: true
    attribute :key, :string, allow_nil?: false, public?: true
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :path, :string, allow_nil?: false, public?: true
    attribute :state, :string, allow_nil?: false, default: "active", public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_path, [:path]
  end
end

defmodule Cartulary.Topology.ScopeRelation do
  @moduledoc false

  use Cartulary.Resource, domain: Cartulary.Topology, table: "scope_relations"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    create :create do
      accept [:source_scope_id, :target_scope_id, :kind, :metadata]
    end

    update :update do
      accept [:kind, :metadata]
    end
  end

  policies do
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    policy action_type(:read) do
      authorize_if {Cartulary.Policy.ScopeAccess, attribute: :source_scope_id}
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :source_scope_id, :uuid, allow_nil?: false, public?: true
    attribute :target_scope_id, :uuid, allow_nil?: false, public?: true
    attribute :kind, :string, allow_nil?: false, default: "related", public?: true
    attribute :metadata, :map, allow_nil?: false, default: %{}
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_relation, [:source_scope_id, :target_scope_id, :kind]
  end
end

defmodule Cartulary.Topology.RoleGrant do
  @moduledoc false

  use Cartulary.Resource, domain: Cartulary.Topology, table: "role_grants"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    create :create do
      accept [:scope_id, :peer_id, :role, :propagate]
    end

    update :update do
      accept [:role, :propagate]
    end
  end

  policies do
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    policy action_type(:read) do
      authorize_if {Cartulary.Policy.ScopeAccess, attribute: :scope_id}
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if {Cartulary.Policy.RoleIn, roles: [:account_admin, :curator, :system]}
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :scope_id, :uuid, allow_nil?: false, public?: true
    attribute :peer_id, :uuid, allow_nil?: false, public?: true
    attribute :role, :string, allow_nil?: false, public?: true
    attribute :propagate, :boolean, allow_nil?: false, default: true, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_grant, [:scope_id, :peer_id]
  end
end
