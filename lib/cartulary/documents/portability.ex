# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Documents.Portability do
  @moduledoc """
  Export, import, and erasure for a single document — the document half of data ownership.

  The promise here is that a user can take their documents out of one Cartulary deployment and
  into another, or delete them for good, without depending on this installation continuing to
  exist. Two rules make that work.

  **Only durable state travels.** A bundle carries the document's identity and metadata, its
  immutable version metadata, and the original bytes of every version. It does *not* carry
  chunks, embeddings, extracted text, or the knowledge derived from them. Those are rebuildable
  caches, and shipping them would silently pin the destination to the source deployment's
  parser and embedding model. Import instead replays each version through ordinary ingest, so
  the target regenerates everything under its own configuration and its own governance gates.

  **Bytes are verified on both sides.** Every blob is re-hashed against the digest its version
  recorded, on export and again on import. A mismatch aborts loudly rather than producing a
  bundle that looks complete and is not.

  ## The `f6-document-1` schema string

  Bundles carry the literal manifest schema `f6-document-1`. The string is a version identity
  for the bundle *format* and nothing else, and it is what import matches on before touching
  anything. Changing the bundle's shape means changing that string, giving the new format a
  changelog entry, and keeping or explicitly dropping the ability to read the old one — an
  importer that silently accepts a differently shaped bundle is how archives get corrupted.

  ## Erasure

  Erasure is the destructive counterpart, and unlike a tombstone it does not preserve the
  document. It removes the derived chunks, the document row itself, and every blob object no
  *other* document still references. Knowledge supported solely by this document's versions is
  erased outright, together with its supporting rows; knowledge that another source also
  supports is kept and merely loses this document's provenance rows. Content-safe audit
  evidence — ids, counts, the action — remains, because the record that an erasure happened is
  itself part of the account's history.

  Shared blobs are never deleted. Storage is content-addressed, so two documents with identical
  bytes point at one object, and removing it would silently destroy the other document.
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

  # The bundle format identity written into every manifest and required by every import. See
  # the moduledoc for what changing it obliges a maintainer to do.
  @schema "f6-document-1"

  @doc """
  Builds a self-contained bundle for one document: metadata, version history, and its bytes.

  The document is read under the caller's own authorization, so a document the actor may not
  see raises not-found rather than exporting.

  Returns `{:ok, bundle}`. The bundle is a plain string-keyed map with a `"manifest"` (schema
  string and counts), the `"document"` metadata, `"versions"` in ascending version order, and
  `"blobs"` — a list in the same order, each entry carrying its content hash, media type, and
  bytes. The manifest states outright that derived chunks are excluded and will be rebuilt on
  import.

  Raises if a stored blob no longer hashes to the digest its version recorded — a bundle is
  either provably intact or it is not produced.
  """
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

            # Verify on the way out, not only on the way in. Silent bit rot in the blob store
            # would otherwise be faithfully copied into the archive and only discovered when
            # someone tries to restore it.
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

  @doc """
  Restores an exported document by replaying every version through ordinary ingest.

  Versions are replayed in ascending version order, and that ordering is required: each ingest
  compares against the document's current content hash, so replaying out of order would produce
  a different history and leave the wrong version current. Because it is ordinary ingest, the
  target rebuilds chunks and embeddings itself and every extracted statement passes the target's
  own governance gates — an import cannot smuggle in pre-approved knowledge.

  Returns `{:ok, results}`, one ingest result per version, or
  `{:error, :unsupported_document_bundle}` when the manifest schema is not one this build reads.

  Raises `ArgumentError` on a blob whose bytes do not match the checksum recorded for them, and
  `KeyError` when the bundle is missing a version's blob.
  """
  def import_document(%Actor{} = actor, %{"manifest" => %{"schema" => @schema}} = bundle) do
    document = Map.fetch!(bundle, "document")
    # The blob list becomes a lookup keyed by content hash, which is how each version finds its
    # bytes below.
    blobs = Map.new(Map.fetch!(bundle, "blobs"), &{Map.fetch!(&1, "content_hash"), &1})

    results =
      bundle
      |> Map.fetch!("versions")
      |> Enum.sort_by(&Map.fetch!(&1, "version"))
      |> Enum.map(fn version ->
        blob = Map.fetch!(blobs, Map.fetch!(version, "content_hash"))
        bytes = Map.fetch!(blob, "bytes")

        # Never trust a bundle's own claim about its bytes. Checking again here is what keeps a
        # corrupted or tampered archive from becoming durable state in the target Account.
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

  # Anything whose manifest schema this build does not recognise is refused rather than
  # best-effort parsed.
  def import_document(_actor, _bundle), do: {:error, :unsupported_document_bundle}

  @doc """
  Permanently removes a document, its chunks, its exclusive bytes, and the knowledge only it
  supported.

  In order: the document's versions are collected, knowledge supported solely by those versions
  is erased (and provenance rows are dropped from knowledge that survives), chunks are
  destroyed, a content-safe audit entry is written, the blob references belonging only to this
  document are worked out, and the document row is destroyed. Blob objects are deleted after the
  transaction commits.

  Returns `:ok`. Raises `Ash.Error.Forbidden` unless the caller owns the document, is a curator
  or account admin, or is the pipeline; raises `Ash.Error.Query.NotFound` if the document is not
  visible to the actor.
  """
  def erase_document(%Actor{} = actor, document_id) when is_binary(document_id) do
    # Blob deletion happens *after* the transaction commits, using the references collected
    # inside it. Deleting objects first would destroy bytes that a rollback still points at,
    # and object storage has no transaction to join. The reverse ordering is recoverable: a
    # crash between commit and delete leaves an unreferenced object, not a dangling row.
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

        # The audit trail outlives the data it describes, so it records only how much was
        # removed. No title, no external id, no hashes of the erased content.
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

        # Only bytes no other document points at may go. Content addressing means an identical
        # file uploaded twice is one stored object shared by two documents.
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

  # Splits the knowledge this document touched into "only this document supported it" and
  # "something else supports it too", then treats the two halves differently.
  #
  # The first half is erased through the governance erasure helper, which also removes the
  # entity mentions, attributions, and provenance that hang off each item. The second half is
  # kept exactly as it is; only this document's provenance rows are dropped, so the statement
  # survives with a truthful, narrower record of what supports it.
  #
  # An item whose provenance list is empty falls into the "sole source" half, because
  # `Enum.all?/2` is vacuously true. In practice every item reached here was found *through* a
  # provenance row, so the empty case does not arise from this call path.
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

  # True when no version of any *other* document references these bytes. This document's own
  # versions are excluded, since they are going away with it. The query is tenant-scoped, which
  # is sufficient because object keys are namespaced by Account: no two Accounts ever share a
  # stored object, even when their documents are byte-identical.
  defp exclusive_blob_ref?(blob_ref, document_id, account_id, actor) do
    DocumentVersion
    |> Ash.Query.filter(blob_ref == ^blob_ref and document_id != ^document_id)
    |> Ash.Query.limit(1)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read_one!(actor: actor)
    |> is_nil()
  end

  # Only fields the target needs to recreate the document as a fresh ingest. Ids, timestamps,
  # the current-version pointer, connector linkage, and processing state are all deliberately
  # absent: they belong to this installation, and the target derives its own.
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

  # Durable version facts only. Extracted text, extraction metadata, and chunk counts are
  # derived caches and are omitted so the target rebuilds them with its own parser and embedder.
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

  # Erasure is irreversible, so it is gated here rather than left to the resource policy alone:
  # the pipeline, an admin, a curator, or the person who owns the document. An ordinary scope
  # member who can read a document cannot destroy it.
  defp authorize_erasure!(document, actor) do
    allowed =
      actor.pipeline? ||
        actor.role in [:account_admin, :curator] ||
        document.owner_peer_id == actor.peer_id

    unless allowed, do: raise(Ash.Error.Forbidden, errors: [])
  end

  # Reads one row by id, tenant-scoped. A row the actor may not see and a row that does not
  # exist raise the same error, so a caller cannot probe for other people's documents.
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

  # Escalates to internal pipeline privileges for the destroys and lifecycle writes no caller
  # may perform directly. The Account is preserved, so this widens what may be written, never
  # which Account it is written to. Authorization for the erasure itself was already checked.
  defp pipeline_actor(%Actor{} = actor), do: %{actor | role: :system, pipeline?: true}
end
