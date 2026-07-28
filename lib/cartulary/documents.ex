# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Documents do
  @moduledoc """
  Ash domain for F6 connector state and rebuildable document chunks.

  Durable document identity and immutable source versions remain raw
  observations in `Cartulary.Observations`. Connector cursors are durable
  authored configuration; chunks and their embeddings are derived caches that
  can be rebuilt from version blobs.
  """

  use Ash.Domain

  resources do
    resource Cartulary.Documents.ConnectorConfig
    resource Cartulary.Documents.DocumentChunk
  end

  defdelegate ingest_bytes(actor, attrs), to: Cartulary.Documents.Service
  defdelegate process_version_for_account(version_id, account_id), to: Cartulary.Documents.Service
  defdelegate register_connector(actor, attrs), to: Cartulary.Documents.Service
  defdelegate enqueue_due_connectors(account_id), to: Cartulary.Documents.Service

  defdelegate sync_connector_for_account(connector_id, account_id),
    to: Cartulary.Documents.Service

  defdelegate tombstone_document(actor, document_id), to: Cartulary.Documents.Service
  defdelegate rebuild_version_for_account(version_id, account_id), to: Cartulary.Documents.Service
  defdelegate export_document(actor, document_id), to: Cartulary.Documents.Portability
  defdelegate import_document(actor, bundle), to: Cartulary.Documents.Portability
  defdelegate erase_document(actor, document_id), to: Cartulary.Documents.Portability
end

defmodule Cartulary.Documents.Validations.ContentSafeConnectorConfig do
  @moduledoc false

  use Ash.Resource.Validation

  @raw_secret_keys ~w(
    apikey authorization clientsecret credential credentials password privatekey
    secret token accesstoken refreshtoken authtoken bearer
  )
  @secret_ref_regex ~r/\A[a-z][a-z0-9+.-]*:[^\s]+\z/

  @impl true
  def validate(changeset, _opts, _context) do
    config = Ash.Changeset.get_attribute(changeset, :config) || %{}
    secret_ref = Ash.Changeset.get_attribute(changeset, :secret_ref)

    cond do
      contains_secret?(config) ->
        {:error, field: :config, message: "must contain secret references, not raw secrets"}

      is_binary(secret_ref) and not Regex.match?(@secret_ref_regex, secret_ref) ->
        {:error, field: :secret_ref, message: "must be a scheme-qualified secret reference"}

      true ->
        :ok
    end
  end

  defp contains_secret?(map) when is_map(map) do
    Enum.any?(map, fn {key, value} ->
      normalized =
        key
        |> to_string()
        |> String.downcase()
        |> String.replace(~r/[-_]/, "")

      normalized in @raw_secret_keys || contains_secret?(value)
    end)
  end

  defp contains_secret?(list) when is_list(list), do: Enum.any?(list, &contains_secret?/1)
  defp contains_secret?(_value), do: false
end

defmodule Cartulary.Documents.ConnectorConfig do
  @moduledoc "Durable schedule, cursor, and content-safe adapter configuration."

  use Cartulary.Resource,
    domain: Cartulary.Documents,
    table: "connector_configs"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    read :read do
      primary? true
    end

    create :create do
      accept [
        :scope_id,
        :owner_peer_id,
        :name,
        :kind,
        :schedule_seconds,
        :config,
        :secret_ref,
        :cursor,
        :status,
        :next_sync_at
      ]

      validate Cartulary.Documents.Validations.ContentSafeConnectorConfig
      validate attribute_in(:status, ~w(active paused))
    end

    update :update_config do
      accept [:name, :schedule_seconds, :config, :secret_ref, :status, :next_sync_at]
      require_atomic? false
      validate Cartulary.Documents.Validations.ContentSafeConnectorConfig
      validate attribute_in(:status, ~w(active paused))
    end

    update :advance_cursor do
      accept [
        :cursor,
        :next_sync_at,
        :last_synced_at,
        :last_error_class,
        :consecutive_failures
      ]

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

    policy action([:create, :update_config, :erase]) do
      authorize_if {Cartulary.Policy.HumanScopeRole, roles: [:account_admin, :curator]}
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    policy action(:advance_cursor) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :scope_id, :uuid, allow_nil?: false, public?: true
    attribute :owner_peer_id, :uuid, allow_nil?: false, public?: true
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :kind, :string, allow_nil?: false, public?: true

    attribute :schedule_seconds, :integer,
      allow_nil?: false,
      default: 3600,
      constraints: [min: 1],
      public?: true

    attribute :config, :map, allow_nil?: false, default: %{}
    attribute :secret_ref, :string
    attribute :cursor, :map, allow_nil?: false, default: %{}
    attribute :status, :string, allow_nil?: false, default: "active", public?: true
    attribute :next_sync_at, :utc_datetime_usec, public?: true
    attribute :last_synced_at, :utc_datetime_usec, public?: true
    attribute :last_error_class, :string, public?: true
    attribute :consecutive_failures, :integer, allow_nil?: false, default: 0, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :scope_name, [:scope_id, :name]
  end
end

defmodule Cartulary.Documents.DocumentChunk do
  @moduledoc "Rebuildable chunk and embedding derived from one immutable document version."

  use Cartulary.Resource,
    domain: Cartulary.Documents,
    table: "document_chunks"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    read :read do
      primary? true
    end

    create :upsert_from_pipeline do
      accept [
        :document_id,
        :document_version_id,
        :scope_id,
        :position,
        :start_byte,
        :end_byte,
        :text,
        :content_hash,
        :embedding,
        :embedding_provider,
        :embedding_model,
        :embedding_version,
        :embedding_dimensions,
        :status
      ]

      upsert? true
      upsert_identity :version_position

      upsert_fields [
        :start_byte,
        :end_byte,
        :text,
        :content_hash,
        :embedding,
        :embedding_provider,
        :embedding_model,
        :embedding_version,
        :embedding_dimensions,
        :status,
        :updated_at
      ]
    end

    update :supersede do
      accept [:status]
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

    policy action_type([:create, :update, :destroy]) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :document_id, :uuid, allow_nil?: false, public?: true
    attribute :document_version_id, :uuid, allow_nil?: false, public?: true
    attribute :scope_id, :uuid, allow_nil?: false, public?: true
    attribute :position, :integer, allow_nil?: false, public?: true
    attribute :start_byte, :integer, allow_nil?: false, public?: true
    attribute :end_byte, :integer, allow_nil?: false, public?: true
    attribute :text, :string, allow_nil?: false
    attribute :content_hash, :string, allow_nil?: false
    attribute :embedding, {:array, :float}, allow_nil?: false
    attribute :embedding_provider, :string, allow_nil?: false, public?: true
    attribute :embedding_model, :string, allow_nil?: false, public?: true
    attribute :embedding_version, :string, allow_nil?: false, public?: true
    attribute :embedding_dimensions, :integer, allow_nil?: false, public?: true
    attribute :status, :string, allow_nil?: false, default: "active", public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :version_position, [:document_version_id, :position]
  end
end
