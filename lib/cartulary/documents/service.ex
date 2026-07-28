# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Documents.Service do
  @moduledoc """
  F6 document ingest, processing, connector sync, tombstone, and rebuild boundary.

  Public writes persist immutable raw versions and enqueue work. Only the
  pipeline parses, chunks, embeds, mints governed knowledge, or changes
  lifecycle state.
  """

  alias Cartulary.Actor
  alias Cartulary.Clock
  alias Cartulary.DataLayer
  alias Cartulary.Documents.BlobStore
  alias Cartulary.Documents.Chunker
  alias Cartulary.Documents.Connector
  alias Cartulary.Documents.ConnectorConfig
  alias Cartulary.Documents.DocumentChunk
  alias Cartulary.Documents.Parser
  alias Cartulary.Governance.Audit
  alias Cartulary.Governance.Engine
  alias Cartulary.Knowledge.KnowledgeItem
  alias Cartulary.Knowledge.KnowledgeRelation
  alias Cartulary.Knowledge.Provenance
  alias Cartulary.Memory
  alias Cartulary.Observability
  alias Cartulary.Observations.Document
  alias Cartulary.Observations.DocumentVersion
  alias Cartulary.Pipeline
  alias Cartulary.Pipeline.Idempotency
  alias Cartulary.Topology.Scope

  require Ash.Query

  def ingest_bytes(%Actor{} = actor, attrs) when is_map(attrs) do
    attrs = normalize_attrs(attrs)
    bytes = Map.fetch!(attrs, "bytes")
    content_hash = Idempotency.content_hash(bytes)

    with {:ok, blob_ref} <-
           BlobStore.put(actor.account_id, content_hash, bytes,
             media_type: Map.get(attrs, "media_type", "application/octet-stream")
           ) do
      result =
        DataLayer.with_actor(actor, fn account, current_actor ->
          do_ingest(account.id, current_actor, attrs, bytes, content_hash, blob_ref)
        end)

      {:ok, result}
    end
  end

  def process_version_for_account(version_id, account_id)
      when is_binary(version_id) and is_binary(account_id) do
    Observability.with_span(:documents, "cartulary.documents.process_version", fn ->
      DataLayer.with_account_id(
        account_id,
        [role: :system, pipeline?: true],
        fn _account, actor ->
          process_version(version_id, account_id, actor)
        end
      )
    end)
  end

  def register_connector(%Actor{} = actor, attrs) when is_map(attrs) do
    attrs = normalize_attrs(attrs)

    DataLayer.with_actor(actor, fn account, current_actor ->
      connector =
        create!(
          ConnectorConfig,
          :create,
          %{
            scope_id: Map.fetch!(attrs, "scope_id"),
            owner_peer_id: Map.get(attrs, "owner_peer_id", current_actor.peer_id),
            name: Map.fetch!(attrs, "name"),
            kind: Map.fetch!(attrs, "kind"),
            schedule_seconds: Map.get(attrs, "schedule_seconds", 3600),
            config: Map.get(attrs, "config", %{}),
            secret_ref: Map.get(attrs, "secret_ref"),
            cursor: Map.get(attrs, "cursor", %{}),
            status: Map.get(attrs, "status", "active"),
            next_sync_at: Map.get(attrs, "next_sync_at", Clock.utc_now())
          },
          account.id,
          current_actor
        )

      Audit.append!(current_actor, account.id, %{
        scope_id: connector.scope_id,
        actor_peer_id: current_actor.peer_id,
        category: "configuration",
        action: "connector.created",
        resource_type: "connector_config",
        resource_id: connector.id,
        metadata: %{
          "kind" => connector.kind,
          "schedule_seconds" => connector.schedule_seconds
        }
      })

      {:ok, _run} = Pipeline.enqueue_connector_sync(connector, current_actor)
      connector
    end)
  end

  def enqueue_due_connectors(account_id) when is_binary(account_id) do
    DataLayer.with_account_id(
      account_id,
      [role: :system, pipeline?: true],
      fn _account, actor ->
        now = Clock.utc_now()

        ConnectorConfig
        |> Ash.Query.filter(status == "active" and (is_nil(next_sync_at) or next_sync_at <= ^now))
        |> Ash.Query.set_tenant(account_id)
        |> Ash.read!(actor: actor)
        |> Enum.map(&Pipeline.enqueue_connector_sync(&1, actor))
      end
    )
  end

  def sync_connector_for_account(connector_id, account_id)
      when is_binary(connector_id) and is_binary(account_id) do
    Observability.with_span(:documents, "cartulary.documents.sync_connector", fn ->
      DataLayer.with_account_id(
        account_id,
        [role: :system, pipeline?: true],
        fn account, actor ->
          connector = read_one!(ConnectorConfig, connector_id, account.id, actor)
          adapter = Connector.adapter!(connector.kind)

          case adapter.pull(connector, connector.cursor) do
            {:ok, page} ->
              apply_connector_page(account.id, actor, connector, page)

            {:error, error} ->
              mark_connector_failed!(connector, actor, error)
              {:error, error}
          end
        end
      )
    end)
  end

  def tombstone_document(%Actor{} = actor, document_id) when is_binary(document_id) do
    DataLayer.with_actor(actor, fn account, current_actor ->
      document = read_one!(Document, document_id, account.id, current_actor)
      tombstone_document_record!(account.id, pipeline_actor(current_actor), document)
    end)
  end

  def rebuild_version_for_account(version_id, account_id),
    do: process_version_for_account(version_id, account_id)

  @doc false
  def load_version_bytes(%DocumentVersion{content: content}) when is_binary(content),
    do: {:ok, content}

  def load_version_bytes(%DocumentVersion{blob_ref: blob_ref}), do: BlobStore.get(blob_ref)

  defp do_ingest(account_id, actor, attrs, bytes, content_hash, blob_ref) do
    connector_config_id = Map.get(attrs, "connector_config_id")
    external_id = Map.get(attrs, "external_id", Ecto.UUID.generate())

    document =
      find_document(account_id, actor, connector_config_id, external_id) ||
        create!(
          Document,
          :create,
          %{
            scope_id: Map.fetch!(attrs, "scope_id"),
            owner_peer_id: Map.get(attrs, "owner_peer_id", actor.peer_id),
            connector_config_id: connector_config_id,
            external_id: external_id,
            title: Map.get(attrs, "title", external_id),
            source_kind: Map.get(attrs, "source_kind", "upload"),
            source_uri: Map.get(attrs, "source_uri"),
            source_metadata: Map.get(attrs, "source_metadata", %{}),
            status: "active"
          },
          account_id,
          actor
        )

    if document.current_content_hash == content_hash do
      %{
        status: :unchanged,
        document: document,
        version: current_version(document, account_id, actor)
      }
    else
      version =
        create!(
          DocumentVersion,
          :create,
          %{
            document_id: document.id,
            scope_id: document.scope_id,
            version: next_version(document.id, account_id, actor),
            content_hash: content_hash,
            byte_size: byte_size(bytes),
            blob_ref: blob_ref,
            media_type: Map.get(attrs, "media_type", "application/octet-stream"),
            source_metadata: Map.get(attrs, "source_metadata", %{}),
            occurred_at: Map.get(attrs, "occurred_at", Clock.utc_now())
          },
          account_id,
          actor
        )

      pipeline_actor = pipeline_actor(actor)

      published =
        document
        |> Ash.Changeset.for_update(:publish_version, %{
          current_version_id: version.id,
          current_content_hash: content_hash,
          status: "active",
          tombstoned_at: nil
        })
        |> Ash.Changeset.set_tenant(account_id)
        |> Ash.update!(actor: pipeline_actor)

      %{status: :created, document: published, version: version}
    end
  end

  defp process_version(version_id, account_id, actor) do
    version = read_one!(DocumentVersion, version_id, account_id, actor)
    document = read_one!(Document, version.document_id, account_id, actor)

    with {:ok, bytes} <- load_version_bytes(version),
         {:ok, parsed} <- Parser.extract(bytes, version.media_type),
         context <- %{account_id: account_id, scope_id: version.scope_id, actor: actor},
         {:ok, chunks} <- Chunker.chunk_and_embed(parsed.text, parsed.format, context),
         :ok <- persist_chunks(version, chunks, actor),
         {:ok, knowledge} <-
           extract_document_knowledge(account_id, actor, document, version, parsed.text),
         :ok <- supersede_prior_derivations(document, version, knowledge, actor) do
      processed =
        version
        |> Ash.Changeset.for_update(:mark_processed, %{
          extracted_text: parsed.text,
          extraction_metadata: parsed.metadata,
          chunk_count: length(chunks),
          embedded_chunk_count: Enum.count(chunks, &(not is_nil(&1.embedding))),
          processing_status: "complete",
          extraction_completed_at: Clock.utc_now()
        })
        |> Ash.Changeset.set_tenant(account_id)
        |> Ash.update!(actor: actor)

      Observability.set_attributes(:documents, %{
        "cartulary.document.version_id" => version.id,
        "cartulary.document.byte_size" => version.byte_size,
        "cartulary.document.chunk_count" => length(chunks),
        "cartulary.document.knowledge_count" => length(knowledge),
        "cartulary.document.parser" => Map.get(parsed.metadata, "parser", "unknown")
      })

      {:ok, processed}
    else
      {:error, error} ->
        mark_version_failed!(version, actor, error)
        {:error, error}
    end
  end

  defp persist_chunks(version, chunks, actor) do
    Enum.each(chunks, fn chunk ->
      create!(
        DocumentChunk,
        :upsert_from_pipeline,
        Map.merge(chunk, %{
          document_id: version.document_id,
          document_version_id: version.id,
          scope_id: version.scope_id,
          status: "active"
        }),
        version.account_id,
        actor
      )
    end)

    :ok
  end

  defp extract_document_knowledge(account_id, actor, document, version, text) do
    owner = read_one!(Cartulary.Accounts.Peer, document.owner_peer_id, account_id, actor)
    scope = read_one!(Scope, document.scope_id, account_id, actor)

    Memory.extract_document_text(account_id, actor, %{
      id: version.id,
      scope_id: document.scope_id,
      peer_id: owner.id,
      peer_key: owner.key,
      scope_path: scope.path,
      role: "document",
      content: text
    })
  end

  defp supersede_prior_derivations(document, version, knowledge, actor) do
    prior_chunks =
      DocumentChunk
      |> Ash.Query.filter(document_id == ^document.id and document_version_id != ^version.id)
      |> Ash.Query.set_tenant(document.account_id)
      |> Ash.read!(actor: actor)

    Enum.each(prior_chunks, fn chunk ->
      chunk
      |> Ash.Changeset.for_update(:supersede, %{status: "superseded"})
      |> Ash.Changeset.set_tenant(document.account_id)
      |> Ash.update!(actor: actor)
    end)

    current_ids = MapSet.new(knowledge, & &1["id"])
    replacement_id = knowledge |> List.first() |> then(&(&1 && &1["id"]))

    prior_version_ids = prior_version_ids(document, version, actor)

    prior_knowledge(document, prior_version_ids, actor)
    |> Enum.reject(&MapSet.member?(current_ids, &1.id))
    |> Enum.filter(fn knowledge ->
      solely_supported_by_versions?(knowledge, prior_version_ids, actor) and
        knowledge.state not in ~w(superseded expired rejected retracted redacted)
    end)
    |> Enum.each(fn old ->
      updated =
        Engine.transition!(
          old,
          actor,
          %{state: "superseded", verification: "document_version_changed"},
          reason: "f6_document_version_superseded",
          channel: "document_sync"
        )

      if replacement_id do
        create!(
          KnowledgeRelation,
          :create_from_pipeline,
          %{
            scope_id: old.scope_id,
            source_knowledge_id: replacement_id,
            target_knowledge_id: old.id,
            kind: "supersedes",
            confidence: 1.0
          },
          old.account_id,
          actor
        )
      end

      updated
    end)

    :ok
  end

  defp prior_knowledge(document, prior_version_ids, actor) do
    knowledge_ids =
      Provenance
      |> Ash.Query.filter(source_type == "document" and document_version_id in ^prior_version_ids)
      |> Ash.Query.set_tenant(document.account_id)
      |> Ash.read!(actor: actor)
      |> Enum.map(& &1.knowledge_item_id)
      |> Enum.uniq()

    KnowledgeItem
    |> Ash.Query.filter(id in ^knowledge_ids)
    |> Ash.Query.set_tenant(document.account_id)
    |> Ash.read!(actor: actor)
  end

  defp prior_version_ids(document, version, actor) do
    DocumentVersion
    |> Ash.Query.filter(document_id == ^document.id and version < ^version.version)
    |> Ash.Query.set_tenant(document.account_id)
    |> Ash.read!(actor: actor)
    |> Enum.map(& &1.id)
  end

  defp apply_connector_page(account_id, actor, connector, page) do
    items = Map.fetch!(page, :items)

    counts =
      Enum.reduce(items, %{created: 0, unchanged: 0, tombstoned: 0}, fn item, counts ->
        apply_connector_item(account_id, actor, connector, item, counts)
      end)

    now = Clock.utc_now()
    cursor = Map.fetch!(page, :cursor)

    updated =
      connector
      |> Ash.Changeset.for_update(:advance_cursor, %{
        cursor: cursor,
        last_synced_at: now,
        next_sync_at: DateTime.add(now, connector.schedule_seconds, :second),
        last_error_class: nil,
        consecutive_failures: 0
      })
      |> Ash.Changeset.set_tenant(account_id)
      |> Ash.update!(actor: actor)

    Audit.append!(actor, account_id, %{
      scope_id: connector.scope_id,
      category: "observation",
      action: "connector.synced",
      resource_type: "connector_config",
      resource_id: connector.id,
      metadata: Map.merge(stringify_keys(counts), %{"item_count" => length(items)})
    })

    if Map.get(page, :has_more?, false) do
      {:ok, _run} = Pipeline.enqueue_connector_sync(updated, actor)
    end

    {:ok, %{connector: updated, counts: counts}}
  end

  defp apply_connector_item(account_id, actor, connector, item, counts) do
    external_id = Map.fetch!(item, :external_id)

    if Map.get(item, :deleted?, false) do
      case find_document(account_id, actor, connector.id, external_id) do
        nil ->
          counts

        document ->
          tombstone_document_record!(account_id, actor, document)
          Map.update!(counts, :tombstoned, &(&1 + 1))
      end
    else
      bytes = Map.fetch!(item, :bytes)
      content_hash = Idempotency.content_hash(bytes)
      {:ok, blob_ref} = BlobStore.put(account_id, content_hash, bytes)

      result =
        do_ingest(
          account_id,
          actor,
          %{
            "scope_id" => connector.scope_id,
            "owner_peer_id" => connector.owner_peer_id,
            "connector_config_id" => connector.id,
            "external_id" => external_id,
            "title" => Map.get(item, :title, external_id),
            "source_kind" => "connector",
            "source_uri" => Map.get(item, :source_uri),
            "source_metadata" => Map.get(item, :metadata, %{}),
            "media_type" => Map.get(item, :media_type, "application/octet-stream"),
            "occurred_at" => Map.get(item, :occurred_at, Clock.utc_now())
          },
          bytes,
          content_hash,
          blob_ref
        )

      Map.update!(counts, result.status, &(&1 + 1))
    end
  end

  defp tombstone_document_record!(account_id, actor, document) do
    tombstoned =
      document
      |> Ash.Changeset.for_update(:tombstone, %{
        status: "tombstoned",
        tombstoned_at: Clock.utc_now()
      })
      |> Ash.Changeset.set_tenant(account_id)
      |> Ash.update!(actor: actor)

    DocumentChunk
    |> Ash.Query.filter(document_id == ^document.id)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
    |> Enum.each(fn chunk ->
      chunk
      |> Ash.Changeset.for_update(:supersede, %{status: "tombstoned"})
      |> Ash.Changeset.set_tenant(account_id)
      |> Ash.update!(actor: actor)
    end)

    version_ids = document_version_ids(document, actor)

    document
    |> all_document_knowledge(version_ids, actor)
    |> Enum.filter(fn knowledge ->
      solely_supported_by_versions?(knowledge, version_ids, actor) and
        knowledge.state not in ~w(retracted redacted rejected superseded expired)
    end)
    |> Enum.each(fn knowledge ->
      Engine.transition!(
        knowledge,
        actor,
        %{state: "retracted", verification: "source_tombstoned"},
        reason: "f6_connector_tombstone",
        channel: "document_sync"
      )
    end)

    Audit.append!(actor, account_id, %{
      scope_id: document.scope_id,
      category: "lifecycle",
      action: "document.tombstoned",
      resource_type: "document",
      resource_id: document.id,
      metadata: %{"connector_config_id" => document.connector_config_id}
    })

    tombstoned
  end

  defp all_document_knowledge(document, version_ids, actor) do
    ids =
      Provenance
      |> Ash.Query.filter(document_version_id in ^version_ids)
      |> Ash.Query.set_tenant(document.account_id)
      |> Ash.read!(actor: actor)
      |> Enum.map(& &1.knowledge_item_id)
      |> Enum.uniq()

    KnowledgeItem
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.set_tenant(document.account_id)
    |> Ash.read!(actor: actor)
  end

  defp document_version_ids(document, actor) do
    DocumentVersion
    |> Ash.Query.filter(document_id == ^document.id)
    |> Ash.Query.set_tenant(document.account_id)
    |> Ash.read!(actor: actor)
    |> Enum.map(& &1.id)
  end

  defp solely_supported_by_versions?(knowledge, version_ids, actor) do
    version_ids = MapSet.new(version_ids)

    provenances =
      Provenance
      |> Ash.Query.filter(knowledge_item_id == ^knowledge.id)
      |> Ash.Query.set_tenant(knowledge.account_id)
      |> Ash.read!(actor: actor)

    provenances != [] and
      Enum.all?(provenances, fn provenance ->
        provenance.document_version_id &&
          MapSet.member?(version_ids, provenance.document_version_id)
      end)
  end

  defp mark_connector_failed!(connector, actor, error) do
    connector
    |> Ash.Changeset.for_update(:advance_cursor, %{
      last_error_class: error_class(error),
      consecutive_failures: connector.consecutive_failures + 1,
      next_sync_at: DateTime.add(Clock.utc_now(), connector.schedule_seconds, :second)
    })
    |> Ash.Changeset.set_tenant(connector.account_id)
    |> Ash.update!(actor: actor)
  end

  defp mark_version_failed!(version, actor, error) do
    version
    |> Ash.Changeset.for_update(:mark_failed, %{
      processing_status: "failed",
      last_error_class: error_class(error)
    })
    |> Ash.Changeset.set_tenant(version.account_id)
    |> Ash.update!(actor: actor)
  end

  defp find_document(account_id, actor, connector_config_id, external_id) do
    query =
      if connector_config_id do
        Ash.Query.filter(
          Document,
          connector_config_id == ^connector_config_id and external_id == ^external_id
        )
      else
        Ash.Query.filter(Document, is_nil(connector_config_id) and external_id == ^external_id)
      end

    query
    |> Ash.Query.limit(1)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read_one!(actor: actor)
  end

  defp current_version(%{current_version_id: nil}, _account_id, _actor), do: nil

  defp current_version(document, account_id, actor),
    do: read_one!(DocumentVersion, document.current_version_id, account_id, actor)

  defp next_version(document_id, account_id, actor) do
    DocumentVersion
    |> Ash.Query.filter(document_id == ^document_id)
    |> Ash.Query.sort(version: :desc)
    |> Ash.Query.limit(1)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read_one!(actor: actor)
    |> case do
      nil -> 1
      version -> version.version + 1
    end
  end

  defp read_one!(resource, id, account_id, actor) do
    resource
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read_one!(actor: actor)
    |> case do
      nil -> raise Ash.Error.Query.NotFound, resource: resource
      record -> record
    end
  end

  defp create!(resource, action, attrs, account_id, actor) do
    resource
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_tenant(account_id)
    |> Ash.Changeset.set_context(%{cartulary_actor: actor})
    |> Ash.Changeset.for_create(action, attrs)
    |> Ash.create!(actor: actor)
  end

  defp pipeline_actor(%Actor{} = actor), do: %{actor | role: :system, pipeline?: true}

  defp normalize_attrs(attrs), do: Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp error_class(%module{}), do: inspect(module)
  defp error_class(error) when is_atom(error), do: Atom.to_string(error)
  defp error_class(_error), do: "document_error"
end
