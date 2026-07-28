# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Observations.Changes.HashContent do
  @moduledoc """
  Ash change that derives a message's SHA-256 content hash from its text.

  The hash is always recomputed from the content and force-written, so a caller cannot supply
  one. Three mechanisms depend on that: the extraction job's idempotency key (same message, same
  bytes, same key, so a retry converges instead of duplicating work), the audit entry, which
  records this hash *instead of* the text, and any later comparison that asks whether two turns
  carried identical content.

  If the changeset has no binary content, it is returned untouched and the resource's own
  `allow_nil?` constraint produces the error.
  """

  use Ash.Resource.Change

  alias Cartulary.Pipeline.Idempotency

  @doc """
  Sets `content_hash` to the lowercase hex SHA-256 of the changeset's `content`.

  Returns the changeset unchanged when no binary content is present. Never raises.
  """
  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :content) do
      content when is_binary(content) ->
        Ash.Changeset.force_change_attribute(
          changeset,
          :content_hash,
          Idempotency.content_hash(content)
        )

      _other ->
        changeset
    end
  end
end

defmodule Cartulary.Observations.Changes.HashContentIfMissing do
  @moduledoc """
  Ash change that fills in a document version's content hash only when the caller did not supply
  one.

  This is the deliberate counterpart to the message hashing change, which always recomputes.
  Document ingest hashes the raw bytes *before* the database transaction, because that digest is
  the address the payload is stored under in the blob store. The version row must carry exactly
  that digest, so a supplied hash wins.

  Recomputing here would be actively wrong: the `content` column is usually empty (the bytes are
  in the blob store) or holds only a legacy inline copy, so a recomputed hash would no longer
  match the stored object, would break the idempotency key of the extraction job, and would make
  unchanged-content sync look like a new version.

  The fallback path — hash the inline content — exists for callers that pass text directly.
  With neither a hash nor content, the changeset is returned untouched and the resource's
  `allow_nil?` constraint reports the missing hash.
  """

  use Ash.Resource.Change

  alias Cartulary.Pipeline.Idempotency

  @doc """
  Ensures `content_hash` is set: keeps a supplied non-empty hash, otherwise hashes `content`.

  Returns the changeset unchanged when neither is usable. Never raises.
  """
  @impl true
  def change(changeset, _opts, _context) do
    case {
      Ash.Changeset.get_attribute(changeset, :content_hash),
      Ash.Changeset.get_attribute(changeset, :content)
    } do
      # A supplied hash is the blob's content address; keep it verbatim.
      {hash, _content} when is_binary(hash) and hash != "" ->
        changeset

      {_hash, content} when is_binary(content) ->
        Ash.Changeset.force_change_attribute(
          changeset,
          :content_hash,
          Idempotency.content_hash(content)
        )

      _other ->
        changeset
    end
  end
end

defmodule Cartulary.Observations.Changes.AuditAndEnqueueMessage do
  @moduledoc """
  Ash change that makes accepting a message, auditing it, and scheduling its extraction one
  transaction.

  After the row is inserted and before the surrounding transaction commits, this hook appends a
  hash-chained audit entry, creates (or reuses) the durable pipeline run for message extraction
  and enqueues its job, and enqueues the Account reconciler. All of it runs in the caller's
  transaction, so an error at any step rolls the message back with everything else.

  That coupling is the point. If the audit entry were appended afterwards, a crash would leave an
  unaudited observation; if the job were enqueued afterwards, a rollback would leave a job
  pointing at a message that does not exist, and a commit followed by a crash would leave an
  observation nobody will ever extract.

  The reconciler enqueue is the safety net for the second case in general: it periodically
  re-drives durable records that were never processed, which is why the extraction job's
  idempotency key is derived from the message id and its content hash — re-driving the same
  observation converges on the same run instead of duplicating knowledge.

  ## Content safety

  The audit entry carries the content hash, the role, and the session id. The message text goes
  nowhere near audit metadata, telemetry, or job arguments.
  """

  use Ash.Resource.Change

  alias Cartulary.Governance.Audit
  alias Cartulary.Pipeline

  @doc """
  Registers the after-action hook that audits the message and enqueues its pipeline work.

  Returns the changeset. At run time the hook returns `{:ok, message}` once the audit entry, the
  extraction run, and the reconciler run are all durable, or the first error, which aborts the
  transaction.
  """
  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.after_action(changeset, fn changeset, message ->
      # The actor may arrive through the Ash context, through the explicit context key used by
      # callers that build changesets by hand, or through Ash's private context.
      actor =
        context.actor || changeset.context[:cartulary_actor] ||
          get_in(changeset.context, [:private, :actor])

      with {:ok, _audit} <-
             Audit.append(actor, message.account_id, %{
               scope_id: message.scope_id,
               actor_peer_id: message.peer_id,
               category: "observation",
               action: "message.ingested",
               resource_type: "message",
               resource_id: message.id,
               # The hash stands in for the text; the metadata stays to non-content facts.
               content_hash: message.content_hash,
               metadata: %{
                 "role" => message.role,
                 "session_id" => message.session_id
               }
             }),
           {:ok, _run} <- Pipeline.enqueue_message_extraction(message, actor),
           {:ok, _reconciler} <- Pipeline.enqueue_reconciler(message.account_id, actor),
           :ok <- maybe_fail(changeset) do
        {:ok, message}
      end
    end)
  end

  # Test-only escape hatch. Setting the private context flag below makes this hook fail *after*
  # the message row, the audit entry, and both jobs have been written, which is the only way to
  # prove from the outside that all four really do roll back together. Nothing in production
  # sets the flag; do not remove it without replacing that regression evidence.
  #
  # The `f2_` in the flag name and the "F2" in the failure message are a frozen legacy tag with
  # no current meaning. The regression test matches on that exact string, so renaming them is a
  # coordinated change across both files rather than a cleanup.
  defp maybe_fail(changeset) do
    if get_in(changeset.context, [:private, :f2_force_rollback?]) do
      {:error, "forced F2 rollback"}
    else
      :ok
    end
  end
end

defmodule Cartulary.Observations.Changes.AuditAndEnqueueDocument do
  @moduledoc """
  Ash change that makes accepting a document version, auditing it, and scheduling its extraction
  one transaction.

  This is the document counterpart of the message hook: after the version row is inserted and
  before the transaction commits, it appends a hash-chained audit entry, creates or reuses the
  durable extraction run and enqueues its job, and enqueues the Account reconciler. A failure at
  any point rolls the version back with the rest.

  One asymmetry is deliberate. The payload bytes were already written to the blob store *before*
  this transaction, addressed by their content hash. If the transaction rolls back, that object
  is left behind as a harmless orphan: because the address is the hash of its contents, the
  orphan can never shadow or corrupt a different payload, and a later ingest of the same bytes
  simply reuses it. Trading a rare orphan blob for a guaranteed-consistent database is the
  intended bargain.

  ## Content safety

  The audit entry carries the content hash plus document id, version number, media type, and
  byte size. Bytes, extracted text, source metadata, connector cursors, and secrets never enter
  audit metadata, telemetry, or job arguments.
  """

  use Ash.Resource.Change

  alias Cartulary.Governance.Audit
  alias Cartulary.Pipeline

  @doc """
  Registers the after-action hook that audits the version and enqueues its pipeline work.

  Returns the changeset. At run time the hook returns `{:ok, version}` once the audit entry, the
  extraction run, and the reconciler run are durable, or the first error, which aborts the
  transaction.
  """
  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.after_action(changeset, fn changeset, version ->
      # Same three-way actor lookup as the message hook: Ash context, explicit context key, or
      # Ash's private context.
      actor =
        context.actor || changeset.context[:cartulary_actor] ||
          get_in(changeset.context, [:private, :actor])

      with {:ok, _audit} <-
             Audit.append(actor, version.account_id, %{
               scope_id: version.scope_id,
               category: "observation",
               action: "document_version.ingested",
               resource_type: "document_version",
               resource_id: version.id,
               content_hash: version.content_hash,
               metadata: %{
                 "document_id" => version.document_id,
                 "version" => version.version,
                 "media_type" => version.media_type,
                 "byte_size" => version.byte_size
               }
             }),
           {:ok, _run} <- Pipeline.enqueue_document_extraction(version, actor),
           {:ok, _reconciler} <- Pipeline.enqueue_reconciler(version.account_id, actor) do
        {:ok, version}
      end
    end)
  end
end
