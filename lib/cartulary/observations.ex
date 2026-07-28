# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Observations do
  @moduledoc """
  Ash domain for durable raw observations and authored document versions.

  Message and document-version content is create-only. This preserves
  `FR-FORM-7` through `FR-FORM-12` and the authored-artifact versioning rule.
  F6 stores document bytes through the configured blob port and keeps immutable
  content hashes, source metadata, and blob references on each durable version.
  """

  use Ash.Domain

  resources do
    resource Cartulary.Observations.Session
    resource Cartulary.Observations.SessionScope
    resource Cartulary.Observations.SessionParticipant
    resource Cartulary.Observations.Message
    resource Cartulary.Observations.Document
    resource Cartulary.Observations.DocumentVersion
  end
end

defmodule Cartulary.Observations.Session do
  @moduledoc false

  use Cartulary.Resource, domain: Cartulary.Observations, table: "sessions"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    read :read do
      primary? true
    end

    create :ensure do
      accept [:scope_id, :peer_id, :external_id, :status, :opened_at]
      upsert? true
      upsert_identity :external_id
      upsert_fields [:status, :updated_at]
    end

    update :update do
      accept [:status, :closed_at]
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

    policy action(:erase) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :scope_id, :uuid, allow_nil?: false, public?: true
    attribute :peer_id, :uuid, allow_nil?: false, public?: true
    attribute :external_id, :string, allow_nil?: false, public?: true
    attribute :status, :string, allow_nil?: false, default: "open", public?: true
    attribute :summary, :string
    attribute :opened_at, :utc_datetime_usec, public?: true
    attribute :closed_at, :utc_datetime_usec, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :external_id, [:external_id]
  end
end

defmodule Cartulary.Observations.SessionScope do
  @moduledoc false

  use Cartulary.Resource, domain: Cartulary.Observations, table: "session_scopes"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    create :ensure do
      accept [:session_id, :scope_id, :classification, :confirmed_at]
      upsert? true
      upsert_identity :session_scope
      upsert_fields [:classification, :confirmed_at, :updated_at]
    end

    update :confirm do
      accept [:classification, :confirmed_at]
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

    policy action(:erase) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :session_id, :uuid, allow_nil?: false, public?: true
    attribute :scope_id, :uuid, allow_nil?: false, public?: true
    attribute :classification, :string, allow_nil?: false, default: "tentative", public?: true
    attribute :confirmed_at, :utc_datetime_usec, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :session_scope, [:session_id, :scope_id]
  end
end

defmodule Cartulary.Observations.SessionParticipant do
  @moduledoc false

  use Cartulary.Resource,
    domain: Cartulary.Observations,
    table: "session_participants"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    create :ensure do
      accept [:session_id, :peer_id, :role, :joined_at]
      upsert? true
      upsert_identity :session_peer
      upsert_fields [:role, :updated_at]
    end

    update :leave do
      accept [:left_at]
    end

    destroy :erase do
      require_atomic? false
    end
  end

  policies do
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
    attribute :session_id, :uuid, allow_nil?: false, public?: true
    attribute :peer_id, :uuid, allow_nil?: false, public?: true
    attribute :role, :string, allow_nil?: false, default: "participant", public?: true
    attribute :joined_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :left_at, :utc_datetime_usec, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :session_peer, [:session_id, :peer_id]
  end
end

defmodule Cartulary.Observations.Message do
  @moduledoc false

  use Cartulary.Resource, domain: Cartulary.Observations, table: "messages"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    create :create do
      accept [:session_id, :scope_id, :peer_id, :role, :content, :occurred_at]

      change Cartulary.Observations.Changes.HashContent
      change Cartulary.Observations.Changes.AuditAndEnqueueMessage
    end

    update :mark_extracted do
      accept [:extraction_completed_at]
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

    policy action_type(:read) do
      authorize_if {Cartulary.Policy.ScopeAccess, attribute: :scope_id}
    end

    policy action(:mark_extracted) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    policy action(:erase) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :session_id, :uuid, allow_nil?: false, public?: true
    attribute :scope_id, :uuid, allow_nil?: false, public?: true
    attribute :peer_id, :uuid, allow_nil?: false, public?: true
    attribute :role, :string, allow_nil?: false, public?: true
    attribute :content, :string, allow_nil?: false, public?: true
    attribute :content_hash, :string, allow_nil?: false
    attribute :occurred_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :extraction_completed_at, :utc_datetime_usec
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end

defmodule Cartulary.Observations.Document do
  @moduledoc false

  use Cartulary.Resource, domain: Cartulary.Observations, table: "documents"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    create :create do
      accept [
        :scope_id,
        :owner_peer_id,
        :connector_config_id,
        :external_id,
        :title,
        :source_kind,
        :source_uri,
        :source_metadata,
        :status
      ]
    end

    update :update_metadata do
      accept [:title, :source_uri, :source_metadata]
    end

    update :publish_version do
      accept [:current_version_id, :current_content_hash, :status, :tombstoned_at]
      require_atomic? false
    end

    update :tombstone do
      accept [:status, :tombstoned_at]
      require_atomic? false
    end

    update :portability_restore do
      public? false
      require_atomic? false
      accept []
      argument :attributes, :map, allow_nil?: false
      change Cartulary.Portability.Changes.RestoreAttributes
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

    policy action(:create) do
      authorize_if {Cartulary.Policy.ScopeRole, roles: [:account_admin, :curator, :member]}
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    policy action(:update_metadata) do
      authorize_if {Cartulary.Policy.ScopeRole, roles: [:account_admin, :curator, :member]}
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    policy action([:publish_version, :tombstone, :erase]) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    policy action(:portability_restore) do
      authorize_if actor_attribute_equals(:pipeline?, true)
      authorize_if {Cartulary.Policy.RoleIn, roles: [:system]}
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :scope_id, :uuid, allow_nil?: false, public?: true
    attribute :owner_peer_id, :uuid, public?: true
    attribute :connector_config_id, :uuid, public?: true
    attribute :current_version_id, :uuid, public?: true
    attribute :current_content_hash, :string, public?: true
    attribute :external_id, :string, public?: true
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :source_kind, :string, allow_nil?: false, default: "upload", public?: true
    attribute :source_uri, :string, public?: true
    attribute :source_metadata, :map, allow_nil?: false, default: %{}, public?: true
    attribute :status, :string, allow_nil?: false, default: "active", public?: true
    attribute :tombstoned_at, :utc_datetime_usec, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :source_external_id, [:connector_config_id, :external_id]
  end
end

defmodule Cartulary.Observations.DocumentVersion do
  @moduledoc false

  use Cartulary.Resource,
    domain: Cartulary.Observations,
    table: "document_versions"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    create :create do
      accept [
        :document_id,
        :scope_id,
        :version,
        :content,
        :content_hash,
        :byte_size,
        :blob_ref,
        :media_type,
        :source_metadata,
        :occurred_at
      ]

      change Cartulary.Observations.Changes.HashContentIfMissing
      change Cartulary.Observations.Changes.AuditAndEnqueueDocument
    end

    update :mark_processed do
      accept [
        :extracted_text,
        :extraction_metadata,
        :chunk_count,
        :embedded_chunk_count,
        :processing_status,
        :extraction_completed_at
      ]

      require_atomic? false
    end

    update :mark_failed do
      accept [:processing_status, :last_error_class]
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

    policy action_type(:read) do
      authorize_if {Cartulary.Policy.ScopeAccess, attribute: :scope_id}
    end

    policy action(:create) do
      authorize_if {Cartulary.Policy.ScopeRole, roles: [:account_admin, :curator, :member]}
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    policy action([:mark_processed, :mark_failed, :erase]) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :document_id, :uuid, allow_nil?: false, public?: true
    attribute :scope_id, :uuid, allow_nil?: false, public?: true
    attribute :version, :integer, allow_nil?: false, public?: true
    attribute :content, :string
    attribute :content_hash, :string, allow_nil?: false, public?: true
    attribute :byte_size, :integer, allow_nil?: false, default: 0, public?: true
    attribute :blob_ref, :string, allow_nil?: false
    attribute :media_type, :string, allow_nil?: false, default: "text/plain", public?: true
    attribute :source_metadata, :map, allow_nil?: false, default: %{}, public?: true
    attribute :extracted_text, :string
    attribute :extraction_metadata, :map, allow_nil?: false, default: %{}
    attribute :chunk_count, :integer, allow_nil?: false, default: 0, public?: true
    attribute :embedded_chunk_count, :integer, allow_nil?: false, default: 0, public?: true
    attribute :processing_status, :string, allow_nil?: false, default: "pending", public?: true
    attribute :last_error_class, :string
    attribute :occurred_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :extraction_completed_at, :utc_datetime_usec
    create_timestamp :inserted_at
  end

  identities do
    identity :document_version, [:document_id, :version]
    identity :document_hash, [:document_id, :content_hash]
  end
end
