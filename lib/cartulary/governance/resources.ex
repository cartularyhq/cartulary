# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Governance.GateRule do
  @moduledoc "Versioned Gate A/B matrix row for confidence, target level, and sensitivity."

  use Cartulary.Resource, domain: Cartulary.Governance, table: "governance_gate_rules"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    create :create do
      accept [
        :scope_id,
        :target_level,
        :sensitivity,
        :minimum_confidence,
        :gate_a_mode,
        :gate_b_mode,
        :minimum_corroboration,
        :requires_consent,
        :pending_max_age_hours,
        :revalidate_after_days,
        :priority,
        :version,
        :active
      ]

      change {Cartulary.Governance.Changes.AuditResource,
              category: "configuration",
              action: "gate_rule.created",
              resource_type: "gate_rule",
              content_fields: [
                :scope_id,
                :target_level,
                :sensitivity,
                :minimum_confidence,
                :gate_a_mode,
                :gate_b_mode,
                :minimum_corroboration,
                :requires_consent,
                :pending_max_age_hours,
                :revalidate_after_days,
                :priority,
                :version,
                :active
              ]}
    end

    update :update do
      accept [
        :minimum_confidence,
        :gate_a_mode,
        :gate_b_mode,
        :minimum_corroboration,
        :requires_consent,
        :pending_max_age_hours,
        :revalidate_after_days,
        :priority,
        :version,
        :active
      ]

      require_atomic? false

      change {Cartulary.Governance.Changes.AuditResource,
              category: "configuration",
              action: "gate_rule.updated",
              resource_type: "gate_rule",
              content_fields: [
                :minimum_confidence,
                :gate_a_mode,
                :gate_b_mode,
                :minimum_corroboration,
                :requires_consent,
                :pending_max_age_hours,
                :revalidate_after_days,
                :priority,
                :version,
                :active
              ]}
    end
  end

  policies do
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if {Cartulary.Policy.HumanRoleIn, roles: [:account_admin, :curator]}
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    policy action_type(:read) do
      authorize_if {Cartulary.Policy.HumanRoleIn, roles: [:account_admin, :curator]}
      authorize_if actor_attribute_equals(:pipeline?, true)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :scope_id, :uuid, public?: true
    attribute :target_level, :string, allow_nil?: false, public?: true
    attribute :sensitivity, :string, allow_nil?: false, public?: true
    attribute :minimum_confidence, :float, allow_nil?: false, default: 1.0, public?: true
    attribute :gate_a_mode, :string, allow_nil?: false, default: "human", public?: true
    attribute :gate_b_mode, :string, allow_nil?: false, default: "human", public?: true
    attribute :minimum_corroboration, :integer, allow_nil?: false, default: 1, public?: true
    attribute :requires_consent, :boolean, allow_nil?: false, default: false, public?: true
    attribute :pending_max_age_hours, :integer, allow_nil?: false, default: 168, public?: true
    attribute :revalidate_after_days, :integer, public?: true
    attribute :priority, :integer, allow_nil?: false, default: 0, public?: true
    attribute :version, :integer, allow_nil?: false, default: 1, public?: true
    attribute :active, :boolean, allow_nil?: false, default: true, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :matrix_cell, [:scope_id, :target_level, :sensitivity, :version]
  end
end

defmodule Cartulary.Governance.ValidationItem do
  @moduledoc "Durable curator/peer queue row for a knowledge gate or lifecycle review."

  use Cartulary.Resource, domain: Cartulary.Governance, table: "validation_items"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    create :enqueue do
      accept [
        :knowledge_id,
        :scope_id,
        :subject_peer_id,
        :target_scope_id,
        :target_level,
        :kind,
        :state,
        :statement_hash,
        :confidence,
        :sensitivity,
        :provenance_ids,
        :conflict_knowledge_ids,
        :assigned_peer_id,
        :due_at,
        :decision,
        :escalated_at,
        :attempt_count,
        :decided_at
      ]

      upsert? true
      upsert_identity :open_knowledge_gate

      upsert_fields [
        :target_scope_id,
        :target_level,
        :state,
        :decision,
        :confidence,
        :sensitivity,
        :provenance_ids,
        :conflict_knowledge_ids,
        :assigned_peer_id,
        :due_at,
        :escalated_at,
        :attempt_count,
        :decided_at,
        :updated_at
      ]
    end

    update :decide do
      accept [
        :state,
        :decision,
        :assigned_peer_id,
        :due_at,
        :escalated_at,
        :attempt_count,
        :decided_at
      ]

      require_atomic? false
    end
  end

  policies do
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    policy action_type([:create, :update]) do
      authorize_if {Cartulary.Policy.HumanRoleIn, roles: [:account_admin, :curator]}
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    policy action_type(:read) do
      authorize_if {Cartulary.Policy.HumanScopeRole,
                    roles: [:account_admin, :curator], attribute: :scope_id}

      authorize_if expr(subject_peer_id == ^actor(:peer_id))
      authorize_if actor_attribute_equals(:pipeline?, true)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :knowledge_id, :uuid, allow_nil?: false, public?: true
    attribute :scope_id, :uuid, allow_nil?: false, public?: true
    attribute :subject_peer_id, :uuid, public?: true
    attribute :target_scope_id, :uuid, public?: true
    attribute :target_level, :string, allow_nil?: false, public?: true
    attribute :kind, :string, allow_nil?: false, public?: true
    attribute :state, :string, allow_nil?: false, default: "pending", public?: true
    attribute :decision, :string, public?: true
    attribute :statement_hash, :string, allow_nil?: false
    attribute :confidence, :float, allow_nil?: false, public?: true
    attribute :sensitivity, :string, allow_nil?: false, public?: true
    attribute :provenance_ids, {:array, :uuid}, allow_nil?: false, default: [], public?: true

    attribute :conflict_knowledge_ids, {:array, :uuid},
      allow_nil?: false,
      default: [],
      public?: true

    attribute :assigned_peer_id, :uuid, public?: true
    attribute :due_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :escalated_at, :utc_datetime_usec, public?: true
    attribute :attempt_count, :integer, allow_nil?: false, default: 0, public?: true
    attribute :decided_at, :utc_datetime_usec, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :open_knowledge_gate, [:knowledge_id, :kind]
  end
end

defmodule Cartulary.Governance.GateDecision do
  @moduledoc "Immutable history row for every automatic or human gate decision."

  use Cartulary.Resource, domain: Cartulary.Governance, table: "gate_decisions"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    create :record do
      accept [
        :validation_item_id,
        :knowledge_id,
        :scope_id,
        :gate,
        :decision,
        :actor_peer_id,
        :channel,
        :verified,
        :from_state,
        :to_state,
        :from_level,
        :to_level,
        :statement_hash,
        :metadata,
        :decided_at
      ]
    end
  end

  policies do
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    policy action(:record) do
      authorize_if {Cartulary.Policy.HumanRoleIn, roles: [:account_admin, :curator]}
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    policy action_type(:read) do
      authorize_if {Cartulary.Policy.HumanRoleIn, roles: [:account_admin, :curator]}
      authorize_if actor_attribute_equals(:pipeline?, true)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :validation_item_id, :uuid, public?: true
    attribute :knowledge_id, :uuid, allow_nil?: false, public?: true
    attribute :scope_id, :uuid, allow_nil?: false, public?: true
    attribute :gate, :string, allow_nil?: false, public?: true
    attribute :decision, :string, allow_nil?: false, public?: true
    attribute :actor_peer_id, :uuid, public?: true
    attribute :channel, :string, allow_nil?: false, public?: true
    attribute :verified, :boolean, allow_nil?: false, default: false, public?: true
    attribute :from_state, :string, public?: true
    attribute :to_state, :string, public?: true
    attribute :from_level, :string, public?: true
    attribute :to_level, :string, public?: true
    attribute :statement_hash, :string, allow_nil?: false
    attribute :metadata, :map, allow_nil?: false, default: %{}
    attribute :decided_at, :utc_datetime_usec, allow_nil?: false, public?: true
    create_timestamp :inserted_at
  end
end

defmodule Cartulary.Governance.Consent do
  @moduledoc "Subject-owned consent for upward attribution of personal knowledge."

  use Cartulary.Resource, domain: Cartulary.Governance, table: "knowledge_consents"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    create :request do
      accept [:knowledge_id, :scope_id, :subject_peer_id, :target_scope_id, :status]
      upsert? true
      upsert_identity :knowledge_target
      upsert_fields [:status, :updated_at]
    end

    update :decide do
      accept [:status, :channel, :verified, :decided_by_peer_id, :decided_at]
      require_atomic? false
    end
  end

  policies do
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    policy action(:request) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    policy action(:decide) do
      authorize_if {Cartulary.Policy.HumanOwns, attribute: :subject_peer_id}
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    policy action_type(:read) do
      authorize_if expr(subject_peer_id == ^actor(:peer_id))
      authorize_if {Cartulary.Policy.HumanRoleIn, roles: [:account_admin, :curator]}
      authorize_if actor_attribute_equals(:pipeline?, true)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :knowledge_id, :uuid, allow_nil?: false, public?: true
    attribute :scope_id, :uuid, allow_nil?: false
    attribute :subject_peer_id, :uuid, allow_nil?: false, public?: true
    attribute :target_scope_id, :uuid, allow_nil?: false, public?: true
    attribute :status, :string, allow_nil?: false, default: "pending", public?: true
    attribute :channel, :string, public?: true
    attribute :verified, :boolean, allow_nil?: false, default: false, public?: true
    attribute :decided_by_peer_id, :uuid, public?: true
    attribute :decided_at, :utc_datetime_usec, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :knowledge_target, [:knowledge_id, :subject_peer_id, :target_scope_id]
  end
end

defmodule Cartulary.Governance.PeerQuery do
  @moduledoc "Frozen peer-routed question over the common validation queue."

  use Cartulary.Resource, domain: Cartulary.Governance, table: "peer_queries"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    create :enqueue do
      accept [
        :validation_item_id,
        :knowledge_id,
        :scope_id,
        :peer_id,
        :kind,
        :statement_text,
        :statement_hash,
        :state,
        :deadline_at,
        :attempts,
        :last_delivered_at,
        :answered_at
      ]

      upsert? true
      upsert_identity :knowledge_kind

      upsert_fields [
        :state,
        :deadline_at,
        :attempts,
        :last_delivered_at,
        :answered_at,
        :updated_at
      ]
    end

    update :update_delivery_state do
      accept [:state, :attempts, :last_delivered_at, :answered_at]
      require_atomic? false
    end

    destroy :erase do
      require_atomic? false
    end
  end

  policies do
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    policy action(:enqueue) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    policy action(:update_delivery_state) do
      authorize_if expr(peer_id == ^actor(:peer_id))
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    policy action(:erase) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    policy action_type(:read) do
      authorize_if expr(peer_id == ^actor(:peer_id))
      authorize_if {Cartulary.Policy.HumanRoleIn, roles: [:account_admin, :curator]}
      authorize_if actor_attribute_equals(:pipeline?, true)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :validation_item_id, :uuid, allow_nil?: false, public?: true
    attribute :knowledge_id, :uuid, allow_nil?: false, public?: true
    attribute :scope_id, :uuid, allow_nil?: false
    attribute :peer_id, :uuid, allow_nil?: false
    attribute :kind, :string, allow_nil?: false, public?: true
    attribute :statement_text, :string, allow_nil?: false, public?: true
    attribute :statement_hash, :string, allow_nil?: false
    attribute :state, :string, allow_nil?: false, default: "pending", public?: true
    attribute :deadline_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :attempts, :integer, allow_nil?: false, default: 0, public?: true
    attribute :last_delivered_at, :utc_datetime_usec, public?: true
    attribute :answered_at, :utc_datetime_usec, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :knowledge_kind, [:knowledge_id, :kind]
  end
end

defmodule Cartulary.Governance.PeerQueryDelivery do
  @moduledoc "Appendable delivery/evidence ledger for an inline peer question."

  use Cartulary.Resource, domain: Cartulary.Governance, table: "peer_query_deliveries"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    create :deliver do
      accept [
        :peer_query_id,
        :scope_id,
        :peer_id,
        :session_id,
        :tool_name,
        :delivered_at,
        :verification
      ]

      upsert? true
      upsert_identity :query_session
      upsert_fields [:tool_name]
    end

    update :answer do
      accept [:shown_text_hash, :verification, :answered_at, :verdict, :conflict]
      require_atomic? false
    end

    destroy :erase do
      require_atomic? false
    end
  end

  policies do
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    policy action([:deliver, :answer]) do
      authorize_if expr(peer_id == ^actor(:peer_id))
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    policy action(:erase) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    policy action_type(:read) do
      authorize_if expr(peer_id == ^actor(:peer_id))
      authorize_if {Cartulary.Policy.HumanRoleIn, roles: [:account_admin, :curator]}
      authorize_if actor_attribute_equals(:pipeline?, true)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :peer_query_id, :uuid, allow_nil?: false, public?: true
    attribute :scope_id, :uuid, allow_nil?: false
    attribute :peer_id, :uuid, allow_nil?: false
    attribute :session_id, :uuid, allow_nil?: false
    attribute :tool_name, :string, allow_nil?: false, public?: true
    attribute :delivered_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :shown_text_hash, :string
    attribute :verification, :string, allow_nil?: false, default: "pending", public?: true
    attribute :answered_at, :utc_datetime_usec, public?: true
    attribute :verdict, :string, public?: true
    attribute :conflict, :boolean, allow_nil?: false, default: false, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :query_session, [:peer_query_id, :session_id]
  end
end

defmodule Cartulary.Governance.PeerAskPreference do
  @moduledoc "Per-peer limits for best-effort inline validation delivery."

  use Cartulary.Resource, domain: Cartulary.Governance, table: "peer_ask_preferences"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    create :ensure do
      accept [:peer_id, :max_per_session, :max_per_day, :paused_until]
      upsert? true
      upsert_identity :peer
      upsert_fields [:peer_id]
    end

    update :restrict do
      argument :max_per_session, :integer
      argument :max_per_day, :integer
      argument :paused_until, :utc_datetime_usec
      require_atomic? false
      change Cartulary.Governance.Changes.ClampAskPreference
    end

    update :configure do
      accept [:max_per_session, :max_per_day, :paused_until]
      require_atomic? false
    end
  end

  policies do
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    policy action([:ensure, :restrict]) do
      authorize_if expr(peer_id == ^actor(:peer_id))
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    policy action(:configure) do
      authorize_if {Cartulary.Policy.HumanRoleIn, roles: [:account_admin, :curator]}
    end

    policy action_type(:read) do
      authorize_if expr(peer_id == ^actor(:peer_id))
      authorize_if {Cartulary.Policy.HumanRoleIn, roles: [:account_admin, :curator]}
      authorize_if actor_attribute_equals(:pipeline?, true)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :peer_id, :uuid, allow_nil?: false, public?: true
    attribute :max_per_session, :integer, allow_nil?: false, default: 3, public?: true
    attribute :max_per_day, :integer, allow_nil?: false, default: 10, public?: true
    attribute :paused_until, :utc_datetime_usec, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :peer, [:peer_id]
  end
end

defmodule Cartulary.Governance.ErasureRequest do
  @moduledoc "Durable request and outcome record for proportionate or strict peer erasure."

  use Cartulary.Resource, domain: Cartulary.Governance, table: "erasure_requests"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    create :request do
      accept [:peer_id, :scope_id, :mode, :requested_by_peer_id, :state, :requested_at]
    end

    update :complete do
      accept [:state, :affected_counts, :completed_at]
      require_atomic? false
    end
  end

  policies do
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    policy action(:request) do
      authorize_if expr(peer_id == ^actor(:peer_id))
      authorize_if {Cartulary.Policy.HumanRoleIn, roles: [:account_admin]}
    end

    policy action(:complete) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    policy action_type(:read) do
      authorize_if expr(peer_id == ^actor(:peer_id))
      authorize_if {Cartulary.Policy.HumanRoleIn, roles: [:account_admin]}
      authorize_if actor_attribute_equals(:pipeline?, true)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :peer_id, :uuid, allow_nil?: false, public?: true
    attribute :scope_id, :uuid
    attribute :mode, :string, allow_nil?: false, default: "proportionate", public?: true
    attribute :requested_by_peer_id, :uuid, public?: true
    attribute :state, :string, allow_nil?: false, default: "pending", public?: true
    attribute :affected_counts, :map, allow_nil?: false, default: %{}, public?: true
    attribute :requested_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :completed_at, :utc_datetime_usec, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end

defmodule Cartulary.Governance.McpTools do
  @moduledoc false

  use Ash.Resource,
    otp_app: :cartulary,
    domain: Cartulary.Governance,
    authorizers: [Ash.Policy.Authorizer]

  actions do
    action :ingest, :map do
      description "Submit a raw observation. This never writes knowledge directly."
      argument :session_id, :string, allow_nil?: false, public?: true
      argument :scope_path, :string, allow_nil?: false, public?: true
      argument :role, :string, default: "user", public?: true
      argument :content, :string, allow_nil?: false, public?: true
      run Cartulary.Governance.Actions.McpIngest
    end

    action :get_context, :map do
      description "Read reasoning-free context and optionally one self-validation question."
      argument :session_id, :string, allow_nil?: false, public?: true
      argument :scope_path, :string, allow_nil?: false, public?: true
      argument :query, :string, public?: true
      argument :limit, :integer, public?: true
      run {Cartulary.Governance.Actions.McpRead, operation: :get_context}
    end

    action :search, :map do
      description "Search governed memory and optionally receive one self-validation question."
      argument :session_id, :string, allow_nil?: false, public?: true
      argument :scope_path, :string, allow_nil?: false, public?: true
      argument :query, :string, allow_nil?: false, public?: true
      argument :profile, :string, default: "balanced", public?: true
      argument :limit, :integer, public?: true
      run {Cartulary.Governance.Actions.McpRead, operation: :search}
    end

    action :ask, :map do
      description "Answer from governed memory and optionally receive one self-validation question."
      argument :session_id, :string, allow_nil?: false, public?: true
      argument :scope_path, :string, allow_nil?: false, public?: true
      argument :question, :string, allow_nil?: false, public?: true
      argument :profile, :string, default: "thorough", public?: true
      run {Cartulary.Governance.Actions.McpRead, operation: :ask}
    end

    action :query_knowledge, :map do
      description "Read structured governed knowledge visible to the calling peer."
      argument :session_id, :string, allow_nil?: false, public?: true
      argument :scope_path, :string, allow_nil?: false, public?: true
      argument :state, :string, public?: true
      argument :limit, :integer, public?: true
      run {Cartulary.Governance.Actions.McpRead, operation: :query_knowledge}
    end

    action :check_readiness, :map do
      description "Check inherited procedural-memory requirements before running a skill."
      argument :session_id, :string, public?: true
      argument :skill, :string, allow_nil?: false, public?: true
      argument :scope_path, :string, allow_nil?: false, public?: true
      argument :peer_id, :uuid, public?: true
      run {Cartulary.Governance.Actions.McpRead, operation: :check_readiness}
    end

    action :resolve_validation, :map do
      description "Answer only a pending validation addressed to the calling peer."
      argument :id, :uuid, allow_nil?: false, public?: true
      argument :verdict, :string, allow_nil?: false, public?: true
      argument :shown_text, :string, public?: true
      argument :correction_text, :string, public?: true
      run Cartulary.Governance.Actions.ResolveValidation
    end

    action :set_ask_preference, :map do
      description "Lower or pause the calling peer's inline validation limits."
      argument :max_per_session, :integer, public?: true
      argument :max_per_day, :integer, public?: true
      argument :pause_for_hours, :integer, public?: true
      run Cartulary.Governance.Actions.SetAskPreference
    end
  end

  policies do
    policy always() do
      authorize_if actor_present()
    end
  end
end
