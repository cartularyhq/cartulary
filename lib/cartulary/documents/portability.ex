# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Documents.Portability do
  @moduledoc """
  F6 document component of the later account-wide logical archive.

  Durable document/version metadata and verified blob bytes travel. Derived
  chunks and embeddings never travel; importing raw versions enqueues their
  normal rebuild path.
  """

  alias Cartulary.Actor
  alias Cartulary.DataLayer
  alias Cartulary.Documents.BlobStore
  alias Cartulary.Documents.DocumentChunk
  alias Cartulary.Documents.Service
  alias Cartulary.Governance.Audit
  alias Cartulary.Governance.Erasure
  alias Cartulary.Knowledge.KnowledgeItem
  alias Cartulary.Knowledge.Provenance
  alias Cartulary.Observations.Document
  alias Cartulary.Observations.DocumentVersion
  alias Cartulary.Pipeline.Idempotency

  require Ash.Query

  @schema "f6-document-1"

  def export_document(%Actor{} = actor, document_id) when is_binary(document_id) do
    bundle =
      DataLayer.with_actor(actor, fn account, current_actor ->
        document = read_one!(Document, document_id, account.id, current_actor)

        versions =
          DocumentVersion
          |> Ash.Query.filter(document_id == ^document.id)
          |> Ash.Query.sort(version: :asc)
          |> Ash.Query.set_tenant(account.id)
          |> Ash.read!(actor: current_actor)

        blobs =
          Enum.map(versions, fn version ->
            {:ok, bytes} = Service.load_version_bytes(version)

            if Idempotency.content_hash(bytes) != version.content_hash do
              raise "document blob checksum mismatch for version #{version.id}"
            end

            %{
              "content_hash" => version.content_hash,
              "media_type" => version.media_type,
              "bytes" => bytes
            }
          end)

        %{
          "manifest" => %{
            "schema" => @schema,
            "document_count" => 1,
            "version_count" => length(versions),
            "blob_count" => length(blobs),
            "derived_chunks" => "excluded_rebuild_on_import"
          },
          "document" => serialize_document(document),
          "versions" => Enum.map(versions, &serialize_version/1),
          "blobs" => blobs
        }
      end)

    {:ok, bundle}
  end

  def import_document(%Actor{} = actor, %{"manifest" => %{"schema" => @schema}} = bundle) do
    document = Map.fetch!(bundle, "document")
    blobs = Map.new(Map.fetch!(bundle, "blobs"), &{Map.fetch!(&1, "content_hash"), &1})

    results =
      bundle
      |> Map.fetch!("versions")
      |> Enum.sort_by(&Map.fetch!(&1, "version"))
      |> Enum.map(fn version ->
        blob = Map.fetch!(blobs, Map.fetch!(version, "content_hash"))
        bytes = Map.fetch!(blob, "bytes")

        if Idempotency.content_hash(bytes) != Map.fetch!(version, "content_hash") do
          raise ArgumentError, "document import blob checksum mismatch"
        end

        {:ok, result} =
          Service.ingest_bytes(actor, %{
            scope_id: Map.fetch!(document, "scope_id"),
            owner_peer_id: Map.fetch!(document, "owner_peer_id"),
            external_id: Map.fetch!(document, "external_id"),
            title: Map.fetch!(document, "title"),
            source_kind: Map.get(document, "source_kind", "import"),
            source_uri: Map.get(document, "source_uri"),
            source_metadata: Map.get(document, "source_metadata", %{}),
            media_type: Map.fetch!(version, "media_type"),
            occurred_at: Map.fetch!(version, "occurred_at"),
            bytes: bytes
          })

        result
      end)

    {:ok, results}
  end

  def import_document(_actor, _bundle), do: {:error, :unsupported_document_bundle}

  def erase_document(%Actor{} = actor, document_id) when is_binary(document_id) do
    blob_refs =
      DataLayer.with_actor(actor, fn account, current_actor ->
        document = read_one!(Document, document_id, account.id, current_actor)
        authorize_erasure!(document, current_actor)
        pipeline = pipeline_actor(current_actor)

        versions =
          DocumentVersion
          |> Ash.Query.filter(document_id == ^document.id)
          |> Ash.Query.set_tenant(account.id)
          |> Ash.read!(actor: pipeline)

        version_ids = MapSet.new(versions, & &1.id)
        erase_document_knowledge!(account.id, pipeline, version_ids)

        chunks =
          DocumentChunk
          |> Ash.Query.filter(document_id == ^document.id)
          |> Ash.Query.set_tenant(account.id)
          |> Ash.read!(actor: pipeline)

        Enum.each(chunks, &destroy!(&1, pipeline))

        Audit.append!(pipeline, account.id, %{
          scope_id: document.scope_id,
          actor_peer_id: current_actor.peer_id,
          category: "deletion",
          action: "document.erased",
          resource_type: "document",
          resource_id: document.id,
          metadata: %{
            "version_count" => length(versions),
            "chunk_count" => length(chunks)
          }
        })

        exclusive_refs =
          versions
          |> Enum.map(& &1.blob_ref)
          |> Enum.uniq()
          |> Enum.filter(&exclusive_blob_ref?(&1, document.id, account.id, pipeline))

        destroy!(document, pipeline)
        exclusive_refs
      end)

    Enum.each(blob_refs, fn blob_ref ->
      :ok = BlobStore.delete(blob_ref)
    end)

    :ok
  end

  defp erase_document_knowledge!(account_id, actor, version_ids) do
    provenances =
      Provenance
      |> Ash.Query.filter(document_version_id in ^MapSet.to_list(version_ids))
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read!(actor: actor)

    knowledge_ids = provenances |> Enum.map(& &1.knowledge_item_id) |> Enum.uniq()

    knowledge =
      KnowledgeItem
      |> Ash.Query.filter(id in ^knowledge_ids)
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read!(actor: actor)

    {sole_source, retained} =
      Enum.split_with(knowledge, fn item ->
        all =
          Provenance
          |> Ash.Query.filter(knowledge_item_id == ^item.id)
          |> Ash.Query.set_tenant(account_id)
          |> Ash.read!(actor: actor)

        Enum.all?(all, fn provenance ->
          provenance.document_version_id &&
            MapSet.member?(version_ids, provenance.document_version_id)
        end)
      end)

    Erasure.erase_knowledge_rows!(account_id, actor, sole_source)

    retained_ids = MapSet.new(retained, & &1.id)

    provenances
    |> Enum.filter(&MapSet.member?(retained_ids, &1.knowledge_item_id))
    |> Enum.each(&destroy!(&1, actor))
  end

  defp exclusive_blob_ref?(blob_ref, document_id, account_id, actor) do
    DocumentVersion
    |> Ash.Query.filter(blob_ref == ^blob_ref and document_id != ^document_id)
    |> Ash.Query.limit(1)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read_one!(actor: actor)
    |> is_nil()
  end

  defp serialize_document(document) do
    %{
      "scope_id" => document.scope_id,
      "owner_peer_id" => document.owner_peer_id,
      "external_id" => document.external_id,
      "title" => document.title,
      "source_kind" => document.source_kind,
      "source_uri" => document.source_uri,
      "source_metadata" => document.source_metadata
    }
  end

  defp serialize_version(version) do
    %{
      "version" => version.version,
      "content_hash" => version.content_hash,
      "byte_size" => version.byte_size,
      "media_type" => version.media_type,
      "source_metadata" => version.source_metadata,
      "occurred_at" => version.occurred_at
    }
  end

  defp authorize_erasure!(document, actor) do
    allowed =
      actor.pipeline? ||
        actor.role in [:account_admin, :curator] ||
        document.owner_peer_id == actor.peer_id

    unless allowed, do: raise(Ash.Error.Forbidden, errors: [])
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

  defp destroy!(record, actor) do
    record
    |> Ash.Changeset.for_destroy(:erase)
    |> Ash.Changeset.set_tenant(record.account_id)
    |> Ash.destroy!(actor: actor)
  end

  defp pipeline_actor(%Actor{} = actor), do: %{actor | role: :system, pipeline?: true}
end
