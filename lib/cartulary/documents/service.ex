# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Documents.Service do
  @moduledoc """
  The implementation of document ingest, processing, connector sync, tombstoning, and rebuild.

  This module is where the document subsystem's rules actually live; the domain module in front
  of it only delegates. It splits cleanly in two halves, and keeping them apart is the point:

  - **Caller-facing writes** persist bytes and metadata and queue work. They never parse, never
    chunk, never embed, and never create knowledge. An uploader or a connector is a source of
    raw observations, nothing more.
  - **Pipeline-internal processing** parses, chunks, embeds, runs the structured extractor, and
    supersedes what the previous version supported. It runs under a system actor with pipeline
    privileges, because those writes must stay consistent with rows a caller cannot see.

  ## Idempotency, in three places

  1. **Identical bytes are free.** The payload is hashed and compared to the document's current
     content hash. Equal means no version, no job, no audit noise — just an `:unchanged` result.
  2. **Chunks upsert.** Re-processing a version rewrites the same rows, so a retried extraction
     job converges instead of duplicating.
  3. **The connector cursor moves last.** A page is applied item by item, and only then is the
     cursor written. A crash mid-page replays the page; because of rule 1 that is nearly free,
     whereas an early cursor write would drop documents with no way to notice.

  ## Transactions

  Every public entry point runs inside one Account-scoped database transaction, opened with the
  Account id set on the connection so Postgres row-level security applies. Creating a document
  version additionally commits the version row, its hash-chain audit entry, its extraction job,
  and a reconciler job together — the job cannot exist without the row, and the row cannot be
  committed without the job.

  ## Content safety

  Audit metadata, telemetry attributes, and job arguments carry ids, hashes, counts, media
  types, parser names, and error classes. They must never carry document bytes, extracted text,
  extracted statements, connector cursors, source metadata, or secrets. Failures are recorded
  as an error class name, never a provider message.
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
  alias Cartulary.Pipeline.Extractor
  alias Cartulary.Pipeline.Idempotency
  alias Cartulary.Topology.Scope

  require Ash.Query

  @doc """
  Accepts one document payload: stores the bytes, then appends a version if the content changed.

  `attrs` may use atom or string keys. `"scope_id"` and `"bytes"` are required and a missing one
  raises `KeyError`. `"external_id"` identifies the document within its source and defaults to a
  fresh UUID, which makes each anonymous upload its own document. `"connector_config_id"`,
  `"title"`, `"source_kind"`, `"source_uri"`, `"source_metadata"`, `"media_type"`,
  `"occurred_at"`, and `"owner_peer_id"` are optional.

  Returns `{:ok, %{status: :created | :unchanged, document: document, version: version}}`.
  On `:unchanged`, `version` is the document's existing current version (or `nil` if it somehow
  has none) and nothing was written.

  A blob-store failure returns `{:error, reason}` before any database work happens. After that
  point the writes are raising Ash calls, so an authorization or validation failure raises.
  """
  def ingest_bytes(%Actor{} = actor, attrs) when is_map(attrs) do
    attrs = normalize_attrs(attrs)
    bytes = Map.fetch!(attrs, "bytes")
    content_hash = Idempotency.content_hash(bytes)

    # The blob is written before the transaction opens, deliberately. Storage is
    # content-addressed, so this put is either a no-op or writes exactly the object that hash
    # names; it can never overwrite different content. If the transaction below then rolls
    # back, the worst outcome is an unreferenced object left in the blob store — far better
    # than a committed version row pointing at bytes that were never stored.
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

  @doc """
  Runs the full derivation for one durable document version: parse, chunk, embed, extract.

  Called from the queued extraction job rather than by a caller, which is why it takes an
  Account id instead of an actor: it opens its own transactions under a system actor with
  pipeline privileges, the only identity allowed to write chunks or mark a version processed.

  Runs in three phases, and the shape is deliberate. A short transaction reads the version and
  everything the derivation needs to know. The derivation itself — blob fetch, parse, embed,
  extract — then runs holding no database connection, because those steps talk to storage and
  to a model and can take minutes; a transaction spanning them would exceed the connection
  pool's checkout-ownership timeout and lose the writes that record work already done and
  already billed. A second short transaction commits everything the derivation produced.

  Returns `{:ok, version}` with processing bookkeeping recorded, or `{:error, reason}`. On
  failure the version is marked failed with an error *class* and the raw version, its blob, its
  audit entry, and its retryable job all survive, so nothing has to be re-ingested.
  """
  def process_version_for_account(version_id, account_id)
      when is_binary(version_id) and is_binary(account_id) do
    Observability.with_span(:documents, "cartulary.documents.process_version", fn ->
      # The actor comes back from the read phase and is reused by the derivation. It is a
      # plain struct naming the Account and the authorization role, so it stays valid after
      # the transaction that produced it ends.
      {actor, version, document, owner, scope} =
        DataLayer.with_account_id(
          account_id,
          [role: :system, pipeline?: true],
          fn _account, actor ->
            {version, document, owner, scope} =
              read_version_for_processing(version_id, account_id, actor)

            {actor, version, document, owner, scope}
          end
        )

      case derive_version(version, document, owner, scope, account_id, actor) do
        {:ok, derived} ->
          DataLayer.with_account_id(
            account_id,
            [role: :system, pipeline?: true],
            fn _account, write_actor ->
              persist_derivation!(derived, version, document, account_id, write_actor)
            end
          )

        {:error, error} ->
          DataLayer.with_account_id(
            account_id,
            [role: :system, pipeline?: true],
            fn _account, write_actor -> mark_version_failed!(version, write_actor, error) end
          )

          {:error, error}
      end
    end)
  end

  @doc """
  Registers an external document source and queues its first sync immediately.

  `attrs` requires `"scope_id"`, `"name"`, and `"kind"`; the kind must match an adapter the
  deployment registered in configuration, though that lookup happens at sync time rather than
  here. `"schedule_seconds"` defaults to one hour, `"status"` to `"active"`, and
  `"next_sync_at"` to now, so a freshly registered connector runs at once. `"config"` must
  hold secret *references*, not credentials; the resource validation rejects settings keys
  whose names look like credentials.

  Returns the created connector. Raises on authorization or validation failure — the resource
  policy admits only an authenticated human holding an admin or curator grant in the scope, or
  a pipeline actor.
  """
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

      # Audit records what kind of source was wired up and how often it polls. The settings
      # map and the secret reference are deliberately absent.
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

  @doc """
  Queues a sync for every active connector in the Account that is due to run.

  Nothing polls connectors on a timer. The Account reconciler runs an equivalent sweep of its
  own, so this entry point is the standalone way to trigger one. Sync jobs carry a
  deterministic key derived from the connector, its cursor, and the scheduled time, so a
  connector swept twice before its job runs does not produce two runs.

  Returns a list of enqueue results, one per due connector.
  """
  def enqueue_due_connectors(account_id) when is_binary(account_id) do
    DataLayer.with_account_id(
      account_id,
      [role: :system, pipeline?: true],
      fn _account, actor ->
        now = Clock.utc_now()

        # A connector that has never run has no next-sync time and counts as due.
        ConnectorConfig
        |> Ash.Query.filter(status == "active" and (is_nil(next_sync_at) or next_sync_at <= ^now))
        |> Ash.Query.set_tenant(account_id)
        |> Ash.read!(actor: actor)
        |> Enum.map(&Pipeline.enqueue_connector_sync(&1, actor))
      end
    )
  end

  @doc """
  Runs one sync pass for a connector: pull a page, apply every item, then move the cursor.

  The adapter is resolved from the connector's kind and asked for the items following its
  current cursor. Every item is applied first — new bytes become a version, identical bytes are
  a no-op, a deletion becomes a tombstone — and the cursor is written only after the whole page
  has been handled. That ordering is the durability guarantee: interrupting this function
  re-fetches the same page next time, which is safe, instead of skipping it, which is not.

  Returns `{:ok, %{connector: connector, counts: counts}}` with per-outcome counts, and queues
  a follow-up sync when the adapter says more pages remain. An adapter error returns
  `{:error, reason}` after recording the error class, bumping the failure counter, and pushing
  the connector's next scheduled sync out by one interval; the cursor is left untouched.

  Raises `ArgumentError` when the connector's kind has no adapter registered in this build, and
  `Ash.Error.Query.NotFound` when the connector does not exist in the Account.
  """
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

  @doc """
  Records that a document no longer exists at its source, without destroying any history.

  The document is looked up under the caller's own authorization, so a caller cannot tombstone
  something they may not see; the mutation itself then runs as the pipeline, because it has to
  touch chunks and knowledge lifecycle rows the caller cannot write.

  Returns the tombstoned document. Raises `Ash.Error.Query.NotFound` when the document is not
  visible to the actor.
  """
  def tombstone_document(%Actor{} = actor, document_id) when is_binary(document_id) do
    DataLayer.with_actor(actor, fn account, current_actor ->
      document = read_one!(Document, document_id, account.id, current_actor)
      tombstone_document_record!(account.id, pipeline_actor(current_actor), document)
    end)
  end

  @doc """
  Regenerates a version's derived caches by re-running processing over the stored bytes.

  Rebuild and first-time processing are the same operation: chunks upsert by position and the
  extractor re-runs, so this is how a changed chunk geometry, a new parser, or a new embedding
  identity is applied to already-ingested documents. Same returns and failure modes as
  `process_version_for_account/2`.
  """
  def rebuild_version_for_account(version_id, account_id),
    do: process_version_for_account(version_id, account_id)

  # Internal to the document subsystem (processing and export both need it), so it stays out of
  # generated docs. Returns {:ok, bytes} for the version's payload.
  #
  # The inline `content` clause exists for history: versions written before bytes moved out of
  # the database kept their text in the row. Rather than rewriting that immutable history, the
  # migration gave those rows a synthetic "legacy-db://" reference so the column could be made
  # non-null; the blob store refuses to read that scheme on purpose. This clause must therefore
  # be tried first. Everything written since lives in the blob store under its content hash.
  @doc false
  def load_version_bytes(%DocumentVersion{content: content}) when is_binary(content),
    do: {:ok, content}

  def load_version_bytes(%DocumentVersion{blob_ref: blob_ref}), do: BlobStore.get(blob_ref)

  # The shared write path behind both direct upload and connector sync, so the two cannot drift
  # apart. Runs inside an already-open Account transaction; the caller has already stored the
  # bytes and computed their hash.
  defp do_ingest(account_id, actor, attrs, bytes, content_hash, blob_ref) do
    connector_config_id = Map.get(attrs, "connector_config_id")
    # No external id means a one-off upload with no stable source identity, so each call gets
    # its own document rather than colliding with an unrelated earlier upload.
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

    # The no-op case. Re-submitting the bytes a document already points at appends no version,
    # writes no audit entry, and queues no extraction, which is what makes a connector safe to
    # re-run over a page it has already handled.
    if document.current_content_hash == content_hash do
      %{
        status: :unchanged,
        document: document,
        version: current_version(document, account_id, actor)
      }
    else
      # Creating the version is the transactional pivot: an after-action hook on this create
      # writes the hash-chain audit entry and enqueues both the extraction job and a reconciler
      # run, all inside the same transaction as the row itself.
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

      # Moving the current-version pointer is pipeline-only work, even when the ingest was a
      # human upload. Clearing the tombstone is intentional: a source that produces content
      # again is alive again, and its history is unbroken because nothing was ever deleted.
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

  # Everything the derivation needs to know before it can start: the version row, its
  # document, and the extractor input built from them. One short transaction, all reads.
  #
  # The extractor input is assembled here rather than later because listing the Account's peer
  # keys — which bounds who a statement may be about — is itself a database read.
  defp read_version_for_processing(version_id, account_id, actor) do
    version = read_one!(DocumentVersion, version_id, account_id, actor)
    document = read_one!(Document, version.document_id, account_id, actor)
    owner = read_one!(Cartulary.Accounts.Peer, document.owner_peer_id, account_id, actor)
    scope = read_one!(Scope, document.scope_id, account_id, actor)

    {version, document, owner, scope}
  end

  # The parts of the derivation that talk to something outside PostgreSQL: the blob store, the
  # parser, the embedding model, and the extraction model. Runs with no transaction open.
  #
  # That is the whole point of the three-phase shape. A transaction owns a pooled database
  # connection for its entire duration, and these four steps can take minutes — the extractor
  # alone may make several provider calls. Holding a connection across them exceeds
  # DBConnection's checkout-ownership timeout, which closes the connection mid-transaction and
  # discards writes recording work that already happened and was already paid for.
  #
  # Order is forced by data dependencies: bytes, then text, then chunks (which need the text
  # and the format the parser reported), then extracted candidates.
  defp derive_version(version, document, owner, scope, account_id, actor) do
    context = %{account_id: account_id, scope_id: version.scope_id, actor: actor}

    with {:ok, bytes} <- load_version_bytes(version),
         {:ok, parsed} <- Parser.extract(bytes, version.media_type),
         {:ok, chunks} <- Chunker.chunk_and_embed(parsed.text, parsed.format, context) do
      # The document's owner is recorded as the observing peer while the version id is carried
      # as provenance, which keeps "who supplied this" separate from "who the statement is
      # about". Documents earn no shortcut: what this produces still enters the ordinary
      # governance lifecycle as a proposal, through the same extractor a chat message uses.
      {observation, extract_context} =
        Memory.document_observation(account_id, actor, %{
          id: version.id,
          scope_id: document.scope_id,
          peer_id: owner.id,
          peer_key: owner.key,
          scope_path: scope.path,
          role: "document",
          content: parsed.text
        })

      with {:ok, items} <- Extractor.extract(observation, extract_context) do
        {:ok, %{parsed: parsed, chunks: chunks, observation: observation, items: items}}
      end
    end
  end

  # Everything the derivation produced, committed together in one short transaction: the chunk
  # cache, the knowledge the version supports, the retirement of what only older versions
  # supported, and the version's own processing bookkeeping.
  #
  # Supersession runs last because it has to know which knowledge the *new* version supports
  # before it can decide what an older version uniquely supported.
  defp persist_derivation!(derived, version, document, account_id, actor) do
    %{parsed: parsed, chunks: chunks, observation: observation, items: items} = derived

    :ok = persist_chunks(version, chunks, actor)

    knowledge = Memory.persist_document_knowledge!(account_id, actor, observation, items)

    :ok = supersede_prior_derivations(document, version, knowledge, actor)

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

    # Content-safe tracing: ids, sizes, counts, and the parser's name. Never the bytes, the
    # extracted text, the statements, or the source metadata.
    Observability.set_attributes(:documents, %{
      "cartulary.document.version_id" => version.id,
      "cartulary.document.byte_size" => version.byte_size,
      "cartulary.document.chunk_count" => length(chunks),
      "cartulary.document.knowledge_count" => length(knowledge),
      "cartulary.document.parser" => Map.get(parsed.metadata, "parser", "unknown")
    })

    {:ok, processed}
  end

  # Writes the derived chunk cache through an upsert keyed on (version, position), so a retried
  # or replayed processing run rewrites rows in place instead of accumulating duplicates.
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

  # Retires what the previous versions of this document supported, now that a newer version has
  # been processed.
  #
  # Two different rules apply. Chunks are a derived cache, so every chunk belonging to an older
  # version is simply marked superseded and stops being retrievable. Knowledge is durable, so a
  # statement is retired only when all three of these hold:
  #
  #   * the new version did not reproduce it;
  #   * every one of its provenance rows points at a prior version of *this* document, meaning
  #     no other source independently supports it; and
  #   * it is not already in a terminal state.
  #
  # Retirement goes through the governance engine rather than a direct update, so the
  # transition writes an append-only lifecycle event and a hash-chained audit entry in the same
  # transaction. The statement and its provenance stay readable — superseded is a state, not a
  # deletion. When the new version produced a replacement, a "supersedes" relation links the two
  # so a reader can follow the change.
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

    # Statements the new version re-produced keep their identity: the extractor merged the new
    # provenance into the existing row, so their ids appear here and they are left alone.
    current_ids = MapSet.new(knowledge, & &1["id"])
    # The relation needs one concrete replacement to point from. The first statement the new
    # version produced stands in for the version as a whole; when the new version produced no
    # knowledge at all there is nothing to link, and the retirement is recorded on its own.
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

  # Every knowledge item that any earlier version of this document contributed to, found by
  # walking provenance rather than by re-reading text.
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

  # Strictly older versions, compared by version number rather than by timestamp so that
  # out-of-order processing of two versions still retires the right side.
  defp prior_version_ids(document, version, actor) do
    DocumentVersion
    |> Ash.Query.filter(document_id == ^document.id and version < ^version.version)
    |> Ash.Query.set_tenant(document.account_id)
    |> Ash.read!(actor: actor)
    |> Enum.map(& &1.id)
  end

  # Applies one adapter page and then commits the connector's progress.
  #
  # The ordering here is the whole durability contract of sync, and it must not be rearranged:
  # every item is handled first, and the cursor is written afterwards. Because the entire
  # function runs in one Account transaction, either the items and the new cursor both commit
  # or neither does. Replaying a page is harmless — unchanged hashes are no-ops and repeated
  # tombstones are idempotent — while advancing the cursor early would drop documents silently.
  defp apply_connector_page(account_id, actor, connector, page) do
    items = Map.fetch!(page, :items)

    counts =
      Enum.reduce(items, %{created: 0, unchanged: 0, tombstoned: 0}, fn item, counts ->
        apply_connector_item(account_id, actor, connector, item, counts)
      end)

    now = Clock.utc_now()
    cursor = Map.fetch!(page, :cursor)

    # Progress commit: new cursor, next run one interval out, and the failure counters cleared
    # because this run succeeded.
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

    # Audit records how much moved, not what moved. No titles, no external ids, no cursor.
    Audit.append!(actor, account_id, %{
      scope_id: connector.scope_id,
      category: "observation",
      action: "connector.synced",
      resource_type: "connector_config",
      resource_id: connector.id,
      metadata: Map.merge(stringify_keys(counts), %{"item_count" => length(items)})
    })

    # Chained paging. The follow-up job is keyed on the *new* cursor, so it is a distinct job
    # from the one that just ran and cannot be deduplicated away against it.
    if Map.get(page, :has_more?, false) do
      {:ok, _run} = Pipeline.enqueue_connector_sync(updated, actor)
    end

    {:ok, %{connector: updated, counts: counts}}
  end

  # One item from an adapter page. Exactly three outcomes are possible, and each of them is
  # safe to repeat: a deletion becomes a tombstone (or nothing, if the document was never seen),
  # unchanged bytes are recognised by hash and do nothing, and new bytes append a version.
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

  # Remote deletion, expressed without deleting anything.
  #
  # The document is flagged, its chunks are flagged, and knowledge that *only* this document
  # supported is retracted through governance. Knowledge with any provenance outside this
  # document's versions is untouched and stays retrievable — losing a source is not the same as
  # the fact having been wrong. Everything remains on disk, so a source that reappears simply
  # republishes a version and clears the tombstone.
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

  # Every knowledge item any version of this document ever contributed to.
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

  # The independent-support test that guards every retirement and erasure decision here.
  #
  # True only when the item has provenance at all *and* every single provenance row points at
  # one of the given document versions. A statement also witnessed in a chat message, or in
  # another document, fails this test and survives. The empty-provenance case is excluded
  # deliberately: an item with no recorded support is not evidence that this document was its
  # only source, so it is left alone rather than retracted on a guess.
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

  # Records a failed pull without touching the cursor, so the same page is retried. The
  # connector's next scheduled sync moves out by one polling interval and its consecutive
  # failure count grows; the failed job itself is still retried by its queue up to the lane's
  # attempt limit.
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

  # Records a failed derivation attempt. The raw version, its blob, its audit entry, and its
  # retryable job all survive, so processing can be attempted again later without re-ingesting.
  defp mark_version_failed!(version, actor, error) do
    version
    |> Ash.Changeset.for_update(:mark_failed, %{
      processing_status: "failed",
      last_error_class: error_class(error)
    })
    |> Ash.Changeset.set_tenant(version.account_id)
    |> Ash.update!(actor: actor)
  end

  # Resolves the existing logical document for a source identifier, or nil.
  #
  # The connector is part of the key, so two connectors may legitimately expose the same
  # external id without colliding. The nil branch is not the same as "any connector": an upload
  # must only ever match another upload, never a connector-managed document with a coincidentally
  # equal identifier.
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

  # Version numbers are dense and start at 1. They come from the highest existing number rather
  # than a counter column, and a unique index on (document, version) turns a concurrent double
  # ingest into a constraint failure instead of two rows claiming the same number.
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

  # Reads one row by id under the actor's authorization. The tenant is always set, so a row from
  # another Account is invisible rather than forbidden, and an id the actor may not see raises
  # the same not-found error as an id that does not exist — the two must be indistinguishable so
  # a caller cannot probe for the existence of other people's documents.
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

  # Creates a row with the tenant set and the actor placed in changeset context. The context
  # copy matters: after-action hooks — the one that writes the audit entry and enqueues the
  # extraction job — read the actor from there when Ash's own actor is not available to them.
  defp create!(resource, action, attrs, account_id, actor) do
    resource
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_tenant(account_id)
    |> Ash.Changeset.set_context(%{cartulary_actor: actor})
    |> Ash.Changeset.for_create(action, attrs)
    |> Ash.create!(actor: actor)
  end

  # Escalates a caller's actor to internal pipeline privileges for the writes only the pipeline
  # may perform — publishing a version pointer, tombstoning, moving lifecycle state. The Account
  # and the peer identity are preserved, so this widens what may be written, never which Account
  # it is written to.
  defp pipeline_actor(%Actor{} = actor), do: %{actor | role: :system, pipeline?: true}

  defp normalize_attrs(attrs), do: Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  # Reduces any failure to a class name. This is what reaches durable columns and telemetry, and
  # it must stay free of provider messages, which can quote the document content that failed.
  defp error_class(%module{}), do: inspect(module)
  defp error_class(error) when is_atom(error), do: Atom.to_string(error)
  defp error_class(_error), do: "document_error"
end
