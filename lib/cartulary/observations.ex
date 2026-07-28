# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Observations do
  @moduledoc """
  Ash domain for raw observations: what was actually said, and which documents were actually
  ingested.

  This is the input side of the system. Agents, humans, and connectors submit observations here
  and nothing else — they cannot write knowledge. The extraction pipeline reads these rows,
  proposes statements, and those statements go through governance before anyone can retrieve
  them. Keeping the two sides apart is what makes "the pipeline is the sole writer of knowledge"
  enforceable rather than aspirational.

  ## What this domain owns

  * `Session` — one conversation or agent run, identified by a caller-supplied external id.
  * `SessionScope` — which scopes a session touches, and how sure we are about each.
  * `SessionParticipant` — which peers took part.
  * `Message` — one raw conversational turn. Content is create-only.
  * `Document` — one logical source document and its current published version.
  * `DocumentVersion` — an immutable snapshot of that document's bytes at one point in time.

  ## Invariants

  * Observed content is never edited. A message is written once; a changed document appends a
    new version rather than mutating the old one. Only bookkeeping fields (processing status,
    extraction timestamps, a document's pointer to its current version) may change afterwards.
  * Creating a `Message` or a `DocumentVersion` also appends an audit entry and enqueues the
    extraction job in the same database transaction, so an accepted observation is always either
    fully recorded and scheduled, or not recorded at all.
  * Every resource is tenanted on `account_id`, and every resource that carries a scope also
    filters reads by the caller's authorized scopes. `SessionParticipant` has no scope column,
    so Account isolation is its only read guard.
  * Document bytes live in the blob store, addressed by their content hash. The database keeps
    the hash, the size, the media type, and a blob reference — not the payload.

  ## Mistakes to avoid

  * Do not add an update action that rewrites `content`, `content_hash`, or a version's bytes.
    Knowledge, audit entries, and idempotency keys are all derived from those values; changing
    them retroactively invalidates evidence that has already been committed elsewhere.
  * Do not enqueue extraction work yourself after creating an observation. The create actions
    already do it transactionally; a second enqueue outside the transaction can survive a
    rollback.
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
  @moduledoc """
  One conversation or agent run that observations are attached to.

  A session is created lazily. Callers do not allocate session ids: they pass whatever handle
  their own system uses as `external_id`, and the first observation carrying that handle creates
  the row. Every later observation with the same handle reuses it. That is why the create action
  is an upsert rather than a plain create — ingest must be safe to retry and safe to race.

  Sessions are metadata, not content. They may legitimately be updated (a session closes) and
  they carry no observed text of their own; the turns live in `Message`. The `summary` column is
  a reserved placeholder: no action accepts it, and the session summary a caller actually
  receives is assembled from governed statements and cached as a projection.

  Erasure is pipeline-only: a session disappears as part of removing a subject's observations,
  not because a caller asked to tidy up.
  """

  use Cartulary.Resource, domain: Cartulary.Observations, table: "sessions"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    read :read do
      primary? true
    end

    # Upsert keyed on the caller's external id, so repeated ingest calls for the same
    # conversation converge on one row. Only `status` is refreshed on a repeat; the scope, the
    # owning peer, and the opening time stay as first observed.
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

    # Creating and closing a session is ordinary Account-scoped metadata work, so those actions
    # are covered by the Account policy above and need no extra role check.
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :scope_id, :uuid, allow_nil?: false, public?: true

    # The peer that opened the session. Participants, including this one, are listed separately.
    attribute :peer_id, :uuid, allow_nil?: false, public?: true

    # The caller's own handle for the conversation; the upsert key.
    attribute :external_id, :string, allow_nil?: false, public?: true
    attribute :status, :string, allow_nil?: false, default: "open", public?: true

    # Reserved and currently unwritten: no action accepts it. Summaries served to callers come
    # from the projection cache, not from this column.
    attribute :summary, :string
    attribute :opened_at, :utc_datetime_usec, public?: true
    attribute :closed_at, :utc_datetime_usec, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  # Unique per Account: two Accounts may use the same external id without colliding.
  identities do
    identity :external_id, [:external_id]
  end
end

defmodule Cartulary.Observations.SessionScope do
  @moduledoc """
  Which scope a session is taking place in, and how certain that association is.

  A session can touch more than one scope, so this is a join row rather than a column on the
  session. `classification` records confidence in the association: it starts `tentative` when
  the scope was inferred and becomes `confirmed` once the caller states it explicitly.

  The distinction matters because scope is what determines who inherits access to anything
  extracted from the session. Treating a tentative association as confirmed would place
  knowledge in a scope nobody agreed to.

  Rows are upserted on session plus scope, so repeated ingest for the same conversation does not
  accumulate duplicates.
  """

  use Cartulary.Resource, domain: Cartulary.Observations, table: "session_scopes"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    # Idempotent on the session/scope pair; a repeat only refreshes the classification.
    create :ensure do
      accept [:session_id, :scope_id, :classification, :confirmed_at]
      upsert? true
      upsert_identity :session_scope
      upsert_fields [:classification, :confirmed_at, :updated_at]
    end

    # Promotes a tentative association once the scope is known for certain.
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

    # "tentative" while the scope was only inferred, "confirmed" once stated explicitly.
    attribute :classification, :string, allow_nil?: false, default: "tentative", public?: true
    attribute :confirmed_at, :utc_datetime_usec, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  # One row per session and scope, per Account.
  identities do
    identity :session_scope, [:session_id, :scope_id]
  end
end

defmodule Cartulary.Observations.SessionParticipant do
  @moduledoc """
  Membership of one peer in one session.

  Each turn already names its own author, so this row is not how authorship is determined. It
  records the weaker fact that a peer was present at all, with what role and between which
  times — the audience of a session rather than the speaker of a turn.

  Rows are upserted on session plus peer, so rejoining a session updates the existing row rather
  than adding a second one. Membership is metadata: it may be updated (a peer leaves) and it
  holds no observed content.

  Unlike the other resources in this domain, this one has no scope column, so reads are gated by
  Account alone. Do not put content here on the assumption that scope filtering will protect it.
  """

  use Cartulary.Resource,
    domain: Cartulary.Observations,
    table: "session_participants"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    # Idempotent on the session/peer pair; only the role is refreshed on a repeat.
    create :ensure do
      accept [:session_id, :peer_id, :role, :joined_at]
      upsert? true
      upsert_identity :session_peer
      upsert_fields [:role, :updated_at]
    end

    # Records departure by stamping `left_at`; the membership row itself survives, because the
    # peer really was present for the turns already recorded.
    update :leave do
      accept [:left_at]
    end

    destroy :erase do
      require_atomic? false
    end
  end

  policies do
    # There is no scope attribute to filter on, so Account isolation is the only read guard here.
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
  @moduledoc """
  One raw conversational turn, exactly as it was observed.

  This is the primary system of record on the input side: the unedited text, who said it, in
  which session and scope, and when. Everything the system later claims to know traces back to
  rows like this one.

  ## Create-only content

  There is no action that changes `content` or `content_hash`. A message is written once and
  then only annotated (`extraction_completed_at`) or erased. That is not squeamishness about
  mutation: the content hash is the idempotency key of the extraction job and the value recorded
  in the audit chain, so editing the text afterwards would orphan work that already committed
  and falsify evidence that has already been hashed into the chain.

  ## One transaction

  Creating a message does four things atomically — insert the row, hash the content, append an
  audit entry, and enqueue the extraction and reconciliation jobs. Either all of it commits or
  none of it does, so there is no state in which an observation exists but will never be
  processed, and none in which a job refers to a message that was rolled back.

  ## Mistakes to avoid

  * Do not enqueue extraction separately after calling `create` — it is already enqueued inside
    the transaction, and a second enqueue outside it can outlive a rollback.
  * Do not copy `content` into audit metadata, telemetry, or job arguments. Those channels carry
    the hash and ids only, and are readable by operators who may not read the message itself.
  """

  use Cartulary.Resource, domain: Cartulary.Observations, table: "messages"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    # Create-only for content. The two changes below run in order: hashing must happen before
    # the audit-and-enqueue hook, which uses the hash as the audit content reference and as the
    # deterministic idempotency key of the extraction job.
    create :create do
      accept [:session_id, :scope_id, :peer_id, :role, :content, :occurred_at]

      change Cartulary.Observations.Changes.HashContent
      change Cartulary.Observations.Changes.AuditAndEnqueueMessage
    end

    # Pipeline bookkeeping only: stamps when extraction finished. It cannot touch content.
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

    # Submitting an observation deliberately needs no role beyond belonging to the Account: any
    # authenticated agent or peer may say what it saw. The restriction that matters is on the
    # other side — none of them can turn an observation into knowledge.

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

    # The scope the turn was observed in. Anything extracted from it inherits this scope.
    attribute :scope_id, :uuid, allow_nil?: false, public?: true

    # Who produced the turn. This is the *source*; who the turn is about is decided later by
    # extraction and recorded on the knowledge statement, not here.
    attribute :peer_id, :uuid, allow_nil?: false, public?: true
    attribute :role, :string, allow_nil?: false, public?: true

    # Verbatim observed text. Never rewritten.
    attribute :content, :string, allow_nil?: false, public?: true

    # SHA-256 of the content, derived on create. Not public, because it is machinery: it keys
    # the extraction job and stands in for the text in the audit chain.
    attribute :content_hash, :string, allow_nil?: false

    # When the turn happened, which may be earlier than when it was submitted.
    attribute :occurred_at, :utc_datetime_usec, allow_nil?: false, public?: true

    # Pipeline bookkeeping; not public.
    attribute :extraction_completed_at, :utc_datetime_usec
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end

defmodule Cartulary.Observations.Document do
  @moduledoc """
  One logical source document: the stable identity behind a series of immutable versions.

  The row holds what stays the same across versions — the scope it belongs to, its owner, the
  connector it came from, its external id and title, and where it currently points. The bytes
  live in `DocumentVersion` rows and, physically, in the blob store.

  ## Current version pointer

  `current_version_id` and `current_content_hash` name the version in force right now. Sync
  compares an incoming payload's hash against `current_content_hash`: an identical hash is a
  no-op, a different hash appends a new version and republishes the pointer. History is never
  rewritten, so an old version stays readable and the statements derived from it keep their
  provenance even after they are superseded.

  ## Deletion is a tombstone

  A document removed at the source is tombstoned (`status` plus `tombstoned_at`), not deleted.
  Knowledge supported only by that document is retracted through governance, while knowledge
  that other sources also support survives. Hard removal happens only through erasure.

  ## Who may do what

  Uploading and editing metadata is available to scope members, curators, and admins. Publishing
  a version, tombstoning, erasing, and the private portability restore are pipeline-internal,
  because each of them has to stay consistent with version rows, blobs, and derived knowledge
  that only the pipeline maintains.
  """

  use Cartulary.Resource, domain: Cartulary.Observations, table: "documents"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    # Registers the logical document only. No content, no audit entry, and no job: those belong
    # to the version that carries the bytes, which is why this action has no attached changes.
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

    # Descriptive fields only. Nothing here can change which bytes the document points at.
    update :update_metadata do
      accept [:title, :source_uri, :source_metadata]
    end

    # Moves the current-version pointer after a new immutable version has been written, and
    # clears any tombstone because the source produced content again.
    update :publish_version do
      accept [:current_version_id, :current_content_hash, :status, :tombstoned_at]
      require_atomic? false
    end

    # Remote deletion. The row and all its versions stay; only the status changes, so provenance
    # for knowledge already derived from the document remains intact.
    update :tombstone do
      accept [:status, :tombstoned_at]
      require_atomic? false
    end

    # Import-only. A logical archive restores documents and versions in dependency order, so the
    # pointer to the current version is written in a second pass once that version exists. The
    # change writes whatever attributes the archive supplied directly, bypassing the accept list
    # on purpose — this is a restore of previously durable state, not new authored input.
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

    # Uploading a document is ordinary member work, but only in a scope where the caller holds
    # one of these roles. The pipeline branch covers connector-driven ingest.
    policy action(:create) do
      authorize_if {Cartulary.Policy.ScopeRole, roles: [:account_admin, :curator, :member]}
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    policy action(:update_metadata) do
      authorize_if {Cartulary.Policy.ScopeRole, roles: [:account_admin, :curator, :member]}
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    # Version publication, tombstoning, and hard deletion must stay consistent with version
    # rows, blobs, chunks, and derived knowledge, so they are pipeline-internal.
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

    # Set when the document arrived through a connector; nil for a direct upload.
    attribute :connector_config_id, :uuid, public?: true

    # Pointer to the version in force. The hash is the sync comparison key: an incoming payload
    # whose hash matches is a no-op, so re-syncing costs nothing and creates no history.
    attribute :current_version_id, :uuid, public?: true
    attribute :current_content_hash, :string, public?: true

    # The source system's own identifier, unique per connector within an Account.
    attribute :external_id, :string, public?: true
    attribute :title, :string, allow_nil?: false, public?: true

    # How the document arrived, e.g. an upload or a named connector kind.
    attribute :source_kind, :string, allow_nil?: false, default: "upload", public?: true
    attribute :source_uri, :string, public?: true

    # Connector-supplied descriptive metadata. It can carry source-side content, so it must not
    # be copied into audit metadata, telemetry, or job arguments.
    attribute :source_metadata, :map, allow_nil?: false, default: %{}, public?: true

    # "active" or tombstoned. A tombstone marks remote deletion without destroying history.
    attribute :status, :string, allow_nil?: false, default: "active", public?: true
    attribute :tombstoned_at, :utc_datetime_usec, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  # One document per connector and external id, per Account. Two connectors may legitimately
  # expose the same external id, which is why the connector is part of the key.
  identities do
    identity :source_external_id, [:connector_config_id, :external_id]
  end
end

defmodule Cartulary.Observations.DocumentVersion do
  @moduledoc """
  An immutable snapshot of a document's bytes at one point in time.

  Each version records the SHA-256 hash of the payload, its size, its media type, the reference
  under which the bytes are stored in the blob store, and when the source produced it. The
  payload itself is not in this table: the blob store holds it, addressed by Account plus
  content hash, so two documents in the same Account with identical bytes share one object.

  ## Immutable source history

  Versions are appended, never edited. The only fields that change after creation are processing
  bookkeeping — extraction results, chunk counts, status, and error class. That is what allows a
  statement extracted from version 3 to keep meaning something after version 4 supersedes it.

  ## Durable versus derived

  Durable: the hash, the size, the media type, the source metadata, the occurrence time, and the
  blob reference. Derived and rebuildable: `extracted_text`, `extraction_metadata`, the chunk
  counts, and everything downstream of them (chunks, vectors). A logical export therefore
  carries version metadata plus checksum-verified blob bytes and deliberately omits the derived
  fields; import re-runs ordinary ingest, which rebuilds them under the target deployment's own
  parser and embedder.

  ## Content safety

  Bytes, extracted text, and source metadata must never be copied into audit metadata,
  telemetry, or job arguments. Those carry ids, hashes, counts, media type, and error classes
  only. `last_error_class` is a class name, not a provider error message.

  A parser or provider failure leaves the raw version, its blob, its audit entry, and its
  retryable job in place, so nothing is lost by failing to process a document.
  """

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

      # Order matters. Hashing runs first because the audit-and-enqueue hook uses the hash as
      # the audit content reference and as the extraction job's idempotency key. Unlike
      # messages, the hash may be supplied: byte ingest already hashed the payload to address
      # the blob, and the version must carry that same digest rather than a hash of whatever
      # inline text happens to be present.
      change Cartulary.Observations.Changes.HashContentIfMissing
      change Cartulary.Observations.Changes.AuditAndEnqueueDocument
    end

    # Records the outcome of parsing, chunking, and embedding. Everything it writes is a
    # rebuildable cache; none of it changes the bytes this version stands for.
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

    # Records a failed processing attempt as a status plus an error *class*. The raw version and
    # its retryable job survive, so a later attempt can succeed without re-ingesting.
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

    # Appending a version is submitting an observation: allowed for scope members, curators, and
    # admins, and for connector-driven ingest running as the pipeline.
    policy action(:create) do
      authorize_if {Cartulary.Policy.ScopeRole, roles: [:account_admin, :curator, :member]}
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    # Processing outcomes and deletion belong to the pipeline; a caller cannot claim a document
    # was processed, nor mark it failed to stop it being retried.
    policy action([:mark_processed, :mark_failed, :erase]) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :document_id, :uuid, allow_nil?: false, public?: true
    attribute :scope_id, :uuid, allow_nil?: false, public?: true

    # Monotonic per document, starting at 1. Ordering history, not a semantic version.
    attribute :version, :integer, allow_nil?: false, public?: true

    # Inline payload. Normally nil, because bytes live in the blob store; it exists for rows
    # that predate blob storage and is not public.
    attribute :content, :string

    # SHA-256 of the payload. It addresses the blob, keys the extraction job, stands in for the
    # bytes in the audit chain, and tells sync whether anything actually changed.
    attribute :content_hash, :string, allow_nil?: false, public?: true
    attribute :byte_size, :integer, allow_nil?: false, default: 0, public?: true

    # Where the bytes actually are. Not public: it is storage addressing, and the adapter behind
    # it (local filesystem or object storage) is a deployment choice with no product meaning.
    attribute :blob_ref, :string, allow_nil?: false
    attribute :media_type, :string, allow_nil?: false, default: "text/plain", public?: true

    # Source-side descriptive metadata; can carry content, so keep it out of audit and telemetry.
    attribute :source_metadata, :map, allow_nil?: false, default: %{}, public?: true

    # Derived parse results. Rebuildable from the blob, excluded from logical export, and not
    # public — retrieval serves document text from the derived chunk cache, not from here.
    attribute :extracted_text, :string
    attribute :extraction_metadata, :map, allow_nil?: false, default: %{}

    # Progress counters for the derived chunk cache; also rebuilt by re-processing.
    attribute :chunk_count, :integer, allow_nil?: false, default: 0, public?: true
    attribute :embedded_chunk_count, :integer, allow_nil?: false, default: 0, public?: true
    attribute :processing_status, :string, allow_nil?: false, default: "pending", public?: true

    # An error class name only, never a provider message, so operators can see failure shapes
    # without seeing document content.
    attribute :last_error_class, :string

    # When the source produced this version, which is not when it was ingested.
    attribute :occurred_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :extraction_completed_at, :utc_datetime_usec

    # No update timestamp: the durable facts of a version never change after creation.
    create_timestamp :inserted_at
  end

  # Two guarantees per Account: version numbers do not repeat within a document, and the same
  # bytes are never stored twice for the same document. The second one is what makes a repeated
  # sync of unchanged content a no-op instead of a growing history.
  identities do
    identity :document_version, [:document_id, :version]
    identity :document_hash, [:document_id, :content_hash]
  end
end
