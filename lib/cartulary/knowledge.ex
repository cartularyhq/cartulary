# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Knowledge do
  @moduledoc """
  Ash domain for natural-language knowledge, provenance, and lifecycle state.

  Knowledge content is immutable after creation. Only the internal pipeline may
  mint or merge knowledge; lifecycle and provenance rows are append-only. This
  is the F1 action boundary for `FR-KN-*`, `FR-FORM-19` through `FR-FORM-23`,
  `AD-DATA-1`, and `AINV-2`.
  """

  use Ash.Domain

  resources do
    resource Cartulary.Knowledge.KnowledgeItem
    resource Cartulary.Knowledge.Attribution
    resource Cartulary.Knowledge.Provenance
    resource Cartulary.Knowledge.KnowledgeRelation
    resource Cartulary.Knowledge.LifecycleEvent
    resource Cartulary.Knowledge.Projection
    resource Cartulary.Knowledge.Entity
    resource Cartulary.Knowledge.EntityMention
  end
end

defmodule Cartulary.Knowledge.KnowledgeItem do
  @moduledoc false

  use Cartulary.Resource, domain: Cartulary.Knowledge, table: "knowledge_items"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    read :read do
      primary? true
    end

    create :create_from_pipeline do
      accept [
        :scope_id,
        :subject_peer_id,
        :subject_scope_id,
        :statement,
        :kind,
        :confidence,
        :sensitivity,
        :state,
        :target_level,
        :verification,
        :held_scope_id,
        :corroboration_count,
        :supersedes_id,
        :source_message_ids,
        :expires_at,
        :revalidate_after,
        :relevant_from,
        :relevant_until,
        :source_message_ids,
        :extracting_model,
        :pipeline_version
      ]

      change Cartulary.Knowledge.Changes.HashStatement
    end

    update :merge_from_pipeline do
      accept [:confidence, :source_message_ids, :corroboration_count]
      require_atomic? false
    end

    update :transition do
      argument :reason, :string, allow_nil?: false
      argument :channel, :string, default: "governance"

      accept [
        :scope_id,
        :state,
        :target_level,
        :verification,
        :held_scope_id,
        :confidence,
        :sensitivity,
        :corroboration_count,
        :supersedes_id,
        :expires_at,
        :revalidate_after,
        :relevant_from,
        :relevant_until,
        :deleted_at
      ]

      require_atomic? false
      change Cartulary.Knowledge.Changes.RecordTransition
    end

    destroy :erase do
      require_atomic? false
    end
  end

  policies do
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    policy action_type(:read) do
      authorize_if {Cartulary.Policy.ScopeAccess, attribute: :scope_id}
      authorize_if expr(subject_peer_id == ^actor(:peer_id))
    end

    policy action([:create_from_pipeline, :merge_from_pipeline]) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    policy action([:transition, :erase]) do
      authorize_if {Cartulary.Policy.HumanRoleIn, roles: [:account_admin, :curator]}
      authorize_if actor_attribute_equals(:pipeline?, true)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :scope_id, :uuid, allow_nil?: false, public?: true
    attribute :subject_peer_id, :uuid, public?: true
    attribute :subject_scope_id, :uuid, public?: true
    attribute :statement, :string, allow_nil?: false, public?: true
    attribute :statement_hash, :string, allow_nil?: false
    attribute :kind, :string, allow_nil?: false, default: "fact", public?: true
    attribute :confidence, :float, allow_nil?: false, default: 0.5, public?: true
    attribute :sensitivity, :string, allow_nil?: false, default: "internal", public?: true
    attribute :state, :string, allow_nil?: false, default: "proposed", public?: true
    attribute :target_level, :string, allow_nil?: false, default: "peer", public?: true
    attribute :verification, :string, allow_nil?: false, default: "pending", public?: true
    attribute :held_scope_id, :uuid, public?: true
    attribute :corroboration_count, :integer, allow_nil?: false, default: 1, public?: true
    attribute :supersedes_id, :uuid, public?: true
    attribute :expires_at, :utc_datetime_usec, public?: true
    attribute :revalidate_after, :utc_datetime_usec, public?: true
    attribute :relevant_from, :utc_datetime_usec, public?: true
    attribute :relevant_until, :utc_datetime_usec, public?: true
    attribute :source_message_ids, {:array, :uuid}, allow_nil?: false, default: [], public?: true
    attribute :extracting_model, :string, public?: true
    attribute :pipeline_version, :string, allow_nil?: false, default: "poc-0", public?: true
    attribute :deleted_at, :utc_datetime_usec
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end

defmodule Cartulary.Knowledge.Attribution do
  @moduledoc false

  use Cartulary.Resource, domain: Cartulary.Knowledge, table: "attributions"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    create :create_from_pipeline do
      accept [
        :knowledge_item_id,
        :scope_id,
        :target_type,
        :target_peer_id,
        :target_scope_id,
        :level
      ]
    end

    destroy :erase do
      require_atomic? false
    end
  end

  policies do
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    policy action_type(:read) do
      authorize_if {Cartulary.Policy.ScopeAccess, attribute: :scope_id}
    end

    policy action(:create_from_pipeline) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    policy action(:erase) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :knowledge_item_id, :uuid, allow_nil?: false, public?: true
    attribute :scope_id, :uuid, allow_nil?: false
    attribute :target_type, :string, allow_nil?: false, public?: true
    attribute :target_peer_id, :uuid, public?: true
    attribute :target_scope_id, :uuid, public?: true
    attribute :level, :string, allow_nil?: false, public?: true
    create_timestamp :inserted_at
  end

  identities do
    identity :knowledge_target,
             [:knowledge_item_id, :target_type, :target_peer_id, :target_scope_id, :level]
  end
end

defmodule Cartulary.Knowledge.Provenance do
  @moduledoc false

  use Cartulary.Resource, domain: Cartulary.Knowledge, table: "provenances"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    create :create_from_pipeline do
      accept [
        :knowledge_item_id,
        :scope_id,
        :source_type,
        :message_id,
        :document_version_id,
        :extracting_model,
        :pipeline_version,
        :occurred_at
      ]
    end

    destroy :erase do
      require_atomic? false
    end
  end

  policies do
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    policy action_type(:read) do
      authorize_if {Cartulary.Policy.ScopeAccess, attribute: :scope_id}
    end

    policy action(:create_from_pipeline) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    policy action(:erase) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :knowledge_item_id, :uuid, allow_nil?: false, public?: true
    attribute :scope_id, :uuid, allow_nil?: false
    attribute :source_type, :string, allow_nil?: false, public?: true
    attribute :message_id, :uuid, public?: true
    attribute :document_version_id, :uuid, public?: true
    attribute :extracting_model, :string, public?: true
    attribute :pipeline_version, :string, allow_nil?: false, public?: true
    attribute :occurred_at, :utc_datetime_usec, allow_nil?: false, public?: true
    create_timestamp :inserted_at
  end
end

defmodule Cartulary.Knowledge.KnowledgeRelation do
  @moduledoc false

  use Cartulary.Resource,
    domain: Cartulary.Knowledge,
    table: "knowledge_relations"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    create :create_from_pipeline do
      accept [:scope_id, :source_knowledge_id, :target_knowledge_id, :kind, :confidence]
    end
  end

  policies do
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    policy action_type(:read) do
      authorize_if {Cartulary.Policy.ScopeAccess, attribute: :scope_id}
    end

    policy action(:create_from_pipeline) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :scope_id, :uuid, allow_nil?: false
    attribute :source_knowledge_id, :uuid, allow_nil?: false, public?: true
    attribute :target_knowledge_id, :uuid, allow_nil?: false, public?: true
    attribute :kind, :string, allow_nil?: false, public?: true
    attribute :confidence, :float, allow_nil?: false, default: 1.0, public?: true
    create_timestamp :inserted_at
  end

  identities do
    identity :unique_relation, [:source_knowledge_id, :target_knowledge_id, :kind]
  end
end

defmodule Cartulary.Knowledge.LifecycleEvent do
  @moduledoc false

  use Cartulary.Resource,
    domain: Cartulary.Knowledge,
    table: "knowledge_lifecycle_events"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    create :record do
      accept [:knowledge_item_id, :scope_id, :from_state, :to_state, :reason, :occurred_at]
    end
  end

  policies do
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    policy action_type(:read) do
      authorize_if {Cartulary.Policy.ScopeAccess, attribute: :scope_id}
    end

    policy action(:record) do
      authorize_if {Cartulary.Policy.RoleIn, roles: [:account_admin, :curator, :system]}
      authorize_if actor_attribute_equals(:pipeline?, true)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :knowledge_item_id, :uuid, allow_nil?: false, public?: true
    attribute :scope_id, :uuid, allow_nil?: false
    attribute :from_state, :string, public?: true
    attribute :to_state, :string, allow_nil?: false, public?: true
    attribute :reason, :string, allow_nil?: false, public?: true
    attribute :occurred_at, :utc_datetime_usec, allow_nil?: false, public?: true
    create_timestamp :inserted_at
  end
end

defmodule Cartulary.Knowledge.Projection do
  @moduledoc false

  use Cartulary.Resource, domain: Cartulary.Knowledge, table: "projections"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    create :create_from_pipeline do
      accept [:scope_id, :peer_id, :session_id, :kind, :version, :content, :source_ids, :dirty]
    end

    update :refresh_from_pipeline do
      accept [:version, :content, :source_ids, :dirty]
    end
  end

  policies do
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    policy action_type(:read) do
      authorize_if {Cartulary.Policy.ScopeAccess, attribute: :scope_id}
    end

    policy action([:create_from_pipeline, :refresh_from_pipeline]) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :scope_id, :uuid, allow_nil?: false
    attribute :peer_id, :uuid, public?: true
    attribute :session_id, :uuid, public?: true
    attribute :kind, :string, allow_nil?: false, public?: true
    attribute :version, :integer, allow_nil?: false, default: 1, public?: true
    attribute :content, :map, allow_nil?: false, default: %{}
    attribute :source_ids, {:array, :uuid}, allow_nil?: false, default: []
    attribute :dirty, :boolean, allow_nil?: false, default: false, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end

defmodule Cartulary.Knowledge.Entity do
  @moduledoc false

  use Cartulary.Resource, domain: Cartulary.Knowledge, table: "entities"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    create :create_from_pipeline do
      accept [:canonical_name, :kind, :aliases, :derived_from]
    end

    update :recompute_from_pipeline do
      accept [:canonical_name, :kind, :aliases, :derived_from]
    end

    destroy :erase do
      require_atomic? false
    end
  end

  policies do
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    policy action([:read, :create_from_pipeline, :recompute_from_pipeline]) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    policy action(:erase) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :canonical_name, :string, allow_nil?: false
    attribute :kind, :string, allow_nil?: false
    attribute :aliases, {:array, :string}, allow_nil?: false, default: []
    attribute :derived_from, {:array, :uuid}, allow_nil?: false, default: []
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :canonical_name_kind, [:canonical_name, :kind]
  end
end

defmodule Cartulary.Knowledge.EntityMention do
  @moduledoc false

  use Cartulary.Resource, domain: Cartulary.Knowledge, table: "entity_mentions"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    create :create_from_pipeline do
      accept [:knowledge_item_id, :scope_id, :entity_id, :surface_form, :confidence]
    end

    destroy :erase do
      require_atomic? false
    end
  end

  policies do
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    policy action([:read, :create_from_pipeline]) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    policy action(:erase) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :knowledge_item_id, :uuid, allow_nil?: false
    attribute :scope_id, :uuid, allow_nil?: false
    attribute :entity_id, :uuid, allow_nil?: false
    attribute :surface_form, :string, allow_nil?: false
    attribute :confidence, :float, allow_nil?: false
    create_timestamp :inserted_at
  end

  identities do
    identity :knowledge_entity_surface, [:knowledge_item_id, :entity_id, :surface_form]
  end
end
