# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Governance do
  @moduledoc """
  Ash domain for append-only audit and governed policy configuration.

  Mutation actions are separated from ordinary member actions as required by
  F1, `FR-GOV-*`, and `AD-SEC-3`.
  """

  use Ash.Domain, extensions: [AshAi]

  resources do
    resource Cartulary.Governance.AuditEvent
    resource Cartulary.Governance.PolicyConfig
    resource Cartulary.Governance.GateRule
    resource Cartulary.Governance.ValidationItem
    resource Cartulary.Governance.GateDecision
    resource Cartulary.Governance.Consent
    resource Cartulary.Governance.PeerQuery
    resource Cartulary.Governance.PeerQueryDelivery
    resource Cartulary.Governance.PeerAskPreference
    resource Cartulary.Governance.ErasureRequest
    resource Cartulary.Governance.McpTools
  end

  tools do
    tool(:ingest, Cartulary.Governance.McpTools, :ingest)
    tool(:get_context, Cartulary.Governance.McpTools, :get_context)
    tool(:search, Cartulary.Governance.McpTools, :search)
    tool(:ask, Cartulary.Governance.McpTools, :ask)
    tool(:query_knowledge, Cartulary.Governance.McpTools, :query_knowledge)
    tool(:resolve_validation, Cartulary.Governance.McpTools, :resolve_validation)
    tool(:set_ask_preference, Cartulary.Governance.McpTools, :set_ask_preference)
  end
end

defmodule Cartulary.Governance.AuditEvent do
  @moduledoc false

  use Cartulary.Resource, domain: Cartulary.Governance, table: "audit_events"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    create :record do
      accept [
        :scope_id,
        :actor_peer_id,
        :category,
        :action,
        :resource_type,
        :resource_id,
        :metadata,
        :content_hash,
        :occurred_at
      ]

      change Cartulary.Governance.Changes.HashAuditEvent
    end
  end

  policies do
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    policy action(:record) do
      authorize_if {Cartulary.Policy.RoleIn, roles: [:account_admin, :curator, :system]}
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    policy action_type(:read) do
      authorize_if {Cartulary.Policy.RoleIn, roles: [:account_admin, :curator, :system]}
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :scope_id, :uuid
    attribute :actor_peer_id, :uuid
    attribute :category, :string, allow_nil?: false, public?: true
    attribute :action, :string, allow_nil?: false, public?: true
    attribute :resource_type, :string, allow_nil?: false, public?: true
    attribute :resource_id, :uuid, public?: true
    attribute :metadata, :map, allow_nil?: false, default: %{}
    attribute :content_hash, :string, public?: true
    attribute :previous_hash, :string
    attribute :event_hash, :string, allow_nil?: false
    attribute :occurred_at, :utc_datetime_usec, allow_nil?: false, public?: true
    create_timestamp :inserted_at
  end
end

defmodule Cartulary.Governance.PolicyConfig do
  @moduledoc false

  use Cartulary.Resource, domain: Cartulary.Governance, table: "policy_configs"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    create :create do
      accept [:scope_id, :key, :value, :version, :active]

      change {Cartulary.Governance.Changes.AuditResource,
              category: "configuration",
              action: "policy_config.created",
              resource_type: "policy_config",
              content_fields: [:key, :value, :version, :active]}
    end

    update :update do
      accept [:value, :version, :active]
      require_atomic? false

      change {Cartulary.Governance.Changes.AuditResource,
              category: "configuration",
              action: "policy_config.updated",
              resource_type: "policy_config",
              content_fields: [:key, :value, :version, :active]}
    end
  end

  policies do
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if {Cartulary.Policy.RoleIn, roles: [:account_admin, :curator, :system]}
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :scope_id, :uuid, public?: true
    attribute :key, :string, allow_nil?: false, public?: true
    attribute :value, :map, allow_nil?: false, default: %{}
    attribute :version, :integer, allow_nil?: false, default: 1, public?: true
    attribute :active, :boolean, allow_nil?: false, default: true, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :scope_key_version, [:scope_id, :key, :version]
  end
end
