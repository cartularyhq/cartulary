# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Knowledge do
  @moduledoc """
  Ash domain for governed knowledge statements, their provenance, and their lifecycle state.

  A knowledge statement is the only durable atom in Cartulary. Everything a caller sees as a
  scope card, a peer profile, or a session summary is a projection built from statements, and
  every entity row is a rebuildable cache derived from them. Nothing here is a second store of
  truth: delete the projections, entities, and vectors and the system can rebuild all of them
  from the statements, their provenance, and their lifecycle history.

  ## What this domain owns

  * `KnowledgeItem` — one governed natural-language statement plus its state machine.
  * `Attribution` — who or which scope a statement is *about*, and whether the subject said it.
  * `Provenance` — which raw observation and which extracting model produced it.
  * `KnowledgeRelation` — typed edges between statements; `supersedes` is the only kind written
    by code in this repository.
  * `LifecycleEvent` — the append-only record of every state change.
  * `Projection` — the rebuildable context caches (scope card, peer profile, session summary).
  * `Entity` and `EntityMention` — rebuildable, pipeline-internal resolution caches.

  ## Invariants this domain enforces

  * Agents and connectors submit raw observations only. Knowledge is minted exclusively by the
    extraction pipeline, so every write action here is gated on a pipeline actor (or, for state
    transitions, on an authenticated human curator).
  * Statement text is immutable. A correction mints a replacement statement and supersedes the
    original; it never rewrites history.
  * Provenance and lifecycle rows are append-only, so the reason a statement exists and the path
    it took through governance stay auditable.
  * Every resource is tenanted on `account_id`. Resources that carry a scope column additionally
    filter reads by the caller's authorized scopes; `Entity` and `EntityMention` instead restrict
    reads to the pipeline actor, so they have no caller-facing surface at all.

  ## Mistakes to avoid

  * Do not add a durable write path that bypasses these actions — direct SQL writes defeat the
    tenancy filters, the audit chain, and the governance gate at once.
  * Do not treat a projection or entity row as authoritative. They lag, they can be marked dirty,
    and erasure recomputes them from the surviving statements.
  * Do not assume a read here is safe to show a caller verbatim: the policies filter by Account
    and scope, but lifecycle filtering (excluding held, proposed, or rejected statements) is the
    caller's responsibility and lives in the retrieval layer.
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
  @moduledoc """
  One governed natural-language statement: the durable atom of Cartulary memory.

  A row is a single claim ("Ana prefers async standups"), the scope it lives in, who or what it
  is *about*, how confident and how sensitive it is, and where it currently sits in the
  governance lifecycle. The statement text and its hash never change after creation. A curator
  edit mints a replacement row and marks the original `superseded`; a merge folds one row's
  corroboration into another and marks the absorbed row `superseded`. Either way the retired row
  keeps its text, its provenance, and its history, so what the system once believed stays
  readable.

  ## Independent axes

  Four pairs of fields are deliberately independent and must not be collapsed:

  * *Subject* (`subject_peer_id` / `subject_scope_id`) is who the claim is about. *Source*
    (`source_message_ids` and the `Provenance` rows) is where the claim came from. A peer
    talking about a colleague produces a statement whose subject is the colleague.
  * *Belief time* (`inserted_at`, `revalidate_after`, `expires_at`) is when the system holds the
    claim. *Valid time* (`relevant_from`, `relevant_until`) is when the claim is true in the
    world. A fact can be freshly learned and long expired, or old and still true.
  * `confidence` (how sure) and `sensitivity` (how exposed it may be) never substitute for one
    another. High confidence does not license wider sharing.
  * `state` is the governance lifecycle; `verification` records *why* the last transition
    happened (for example an automatic gate keep, a curator approval, or a subject dispute).

  ## Lifecycle

  Every extracted statement starts as `proposed` — the create action refuses any other state.
  The governance layer then moves it to `active` (retrievable), `provisional` (visible only to
  the peer it came from while a human decision is pending), `held` (a scope or account level
  proposal parked at its source scope and excluded from retrieval), `rejected`, `contested`,
  `needs_revalidation`, `expired`, `superseded`, `redacted`, `stale`, or `retracted`. Only the
  `transition` action may change state, and it always writes a `LifecycleEvent` and an audit
  entry in the same transaction.

  ## Mistakes to avoid

  * Do not write knowledge from web, retrieval, or connector code. `create_from_pipeline` and
    `merge_from_pipeline` require a pipeline actor precisely so that raw observations remain the
    only thing an agent can submit.
  * Do not update state with a plain `Ash.update` on the attributes — bypassing `transition`
    would silently skip the lifecycle event and the audit chain.
  * Do not treat a successful read as "safe to answer with". The policies filter Account and
    scope; they do not filter lifecycle state, so a caller that ignores `state` can leak held or
    rejected content.
  * Do not reuse an embedding whose provider, model, version, and dimensions do not match the
    currently configured embedder. Vectors are only comparable within one pinned identity; a
    mismatch has to be re-embedded, never silently substituted.
  """

  use Cartulary.Resource, domain: Cartulary.Knowledge, table: "knowledge_items"

  # Every query and write is confined to one Account by the Ash tenant, which this resource
  # requires. PostgreSQL row-level security repeats the same check underneath, against a
  # transaction-local Account setting: with no Account set, the policy matches no rows.
  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    read :read do
      primary? true
    end

    # Pipeline-only. The extractor is the sole writer of knowledge; the `state` validation below
    # pins new rows to `proposed` so the governance gate, not the extractor, decides visibility.
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
        :extracting_provider,
        :extracting_model,
        :extracting_model_version,
        :prompt_version,
        :embedding_provider,
        :embedding_model,
        :embedding_version,
        :embedding_dimensions,
        :pipeline_version
      ]

      # Derives `statement_hash` from the statement text. The hash is never accepted from the
      # caller, because deduplication, corroboration merging, and the content-safe audit chain
      # all key off it.
      change Cartulary.Knowledge.Changes.HashStatement

      validate attribute_in(:kind, ~w(fact preference event relation skill))
      validate attribute_in(:sensitivity, ~w(public internal personal restricted))
      validate attribute_in(:state, ~w(proposed))
      validate attribute_in(:target_level, ~w(peer scope account))
    end

    # Re-observing the same statement corroborates the existing row instead of creating a
    # duplicate. Only the corroboration fields are accepted: the statement, its subject, and its
    # lifecycle state cannot change here. Non-atomic because callers compute the merged values
    # from the loaded row (union of source ids, max confidence, incremented count).
    update :merge_from_pipeline do
      accept [:confidence, :source_message_ids, :corroboration_count]
      require_atomic? false
    end

    # Attaches or replaces the semantic vector. The four identity fields travel with the vector
    # so a later reader can tell whether it was produced by the currently configured embedder.
    update :index_from_pipeline do
      accept [
        :embedding,
        :embedding_provider,
        :embedding_model,
        :embedding_version,
        :embedding_dimensions
      ]

      require_atomic? false
    end

    # The only legal way to change lifecycle state. `reason` is mandatory because the lifecycle
    # event and the audit entry both record it; `channel` records which surface drove the
    # decision (governance UI, sweeper, peer answer). Statement text is deliberately absent from
    # the accepted list — a state change can never rewrite the claim.
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

      # Non-atomic on purpose: the change below needs the pre-update row to know which state the
      # item is leaving, which an atomic SQL update would not provide.
      require_atomic? false

      # Writes the append-only lifecycle event and the hash-chained audit entry inside this same
      # transaction, so a state change can never commit without its evidence.
      change Cartulary.Knowledge.Changes.RecordTransition

      validate attribute_in(
                 :state,
                 ~w(proposed active provisional held needs_revalidation superseded expired rejected contested redacted stale retracted)
               )

      validate attribute_in(:sensitivity, ~w(public internal personal restricted))
      validate attribute_in(:target_level, ~w(peer scope account))
    end

    # Hard delete, reached only through the subject-erasure flow. Ordinary retirement of a
    # statement is a `transition` to a terminal state, which keeps the row and its history.
    destroy :erase do
      require_atomic? false
    end
  end

  # All applicable policies must pass, and within one policy any `authorize_if` may satisfy it.
  policies do
    # Account isolation applies to every action, including the pipeline's own writes.
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    # A reader sees statements in the scopes their resolved roles allow, plus every statement
    # about themselves regardless of scope — that self-view is what makes contesting and erasure
    # requests possible. Neither branch filters lifecycle state; the caller must do that.
    policy action_type(:read) do
      authorize_if {Cartulary.Policy.ScopeAccess, attribute: :scope_id}
      authorize_if expr(subject_peer_id == ^actor(:peer_id))
    end

    # Minting, corroborating, and embedding are pipeline-internal. No human role can reach them,
    # which is what keeps "agents submit observations, the pipeline writes knowledge" true.
    policy action([:create_from_pipeline, :merge_from_pipeline, :index_from_pipeline]) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    # Curator decisions are human-only: `HumanRoleIn` matches only password-authenticated
    # identities, so a machine API key with an admin role still cannot approve, reject, or erase.
    # The pipeline branch covers automatic gate results, the aging sweeper, and erasure jobs.
    policy action([:transition, :erase]) do
      authorize_if {Cartulary.Policy.HumanRoleIn, roles: [:account_admin, :curator]}
      authorize_if actor_attribute_equals(:pipeline?, true)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false

    # Where the statement lives, and therefore who inherits access to it.
    attribute :scope_id, :uuid, allow_nil?: false, public?: true

    # Exactly one of these two identifies the subject: the peer the claim is about, or the scope
    # the claim characterises. Neither is the source of the claim.
    attribute :subject_peer_id, :uuid, public?: true
    attribute :subject_scope_id, :uuid, public?: true

    attribute :statement, :string,
      allow_nil?: false,
      constraints: [min_length: 1],
      public?: true

    # Derived from the statement, never accepted from a caller. Deduplication keys off it, and
    # audit events carry this hash instead of the text so the audit log stays content-free.
    attribute :statement_hash, :string, allow_nil?: false

    attribute :kind, :string,
      allow_nil?: false,
      default: "fact",
      public?: true

    attribute :confidence, :float,
      allow_nil?: false,
      default: 0.5,
      constraints: [min: 0.0, max: 1.0],
      public?: true

    attribute :sensitivity, :string,
      allow_nil?: false,
      default: "internal",
      public?: true

    attribute :state, :string,
      allow_nil?: false,
      default: "proposed",
      public?: true

    attribute :target_level, :string,
      allow_nil?: false,
      default: "peer",
      public?: true

    # Why the row is in its current state: "pending", an automatic keep or rejection, a curator
    # decision, a subject confirmation or dispute, an expiry, and so on.
    attribute :verification, :string, allow_nil?: false, default: "pending", public?: true

    # Where a scope- or account-level proposal is parked while it waits for approval. A held
    # item stays at its source scope and must not appear in retrieval at the requested level.
    attribute :held_scope_id, :uuid, public?: true

    # How many independent observations produced the same statement. Starts at 1 and is raised
    # by the corroboration merge, never by re-extraction of the same message.
    attribute :corroboration_count, :integer, allow_nil?: false, default: 1, public?: true

    # Links a statement to its replacement counterpart. A curator edit sets it on the new row,
    # pointing back at the text being replaced; a merge sets it on the row being absorbed,
    # pointing at the surviving statement. In both directions the retired row keeps its own
    # text, provenance, and lifecycle trail.
    attribute :supersedes_id, :uuid, public?: true

    # Belief time: when the system should stop trusting or should re-ask about this claim.
    attribute :expires_at, :utc_datetime_usec, public?: true
    attribute :revalidate_after, :utc_datetime_usec, public?: true

    # Valid time: the window in which the claim is true in the world, independent of belief.
    attribute :relevant_from, :utc_datetime_usec, public?: true
    attribute :relevant_until, :utc_datetime_usec, public?: true

    # Raw messages that contributed this statement. Erasure prunes ids from this list rather
    # than deleting a statement that other sources still support.
    attribute :source_message_ids, {:array, :uuid}, allow_nil?: false, default: [], public?: true

    # Which model, at which version, under which prompt produced the statement. Kept so an
    # extractor regression can be traced to the exact rows it created.
    attribute :extracting_provider, :string, public?: true
    attribute :extracting_model, :string, public?: true
    attribute :extracting_model_version, :string, public?: true
    attribute :prompt_version, :string, public?: true

    # Embedding identity. Vectors are only comparable inside one provider/model/version/
    # dimensions tuple; a mismatch means re-embed, never reuse.
    attribute :embedding_provider, :string, public?: true
    attribute :embedding_model, :string, public?: true
    attribute :embedding_version, :string, public?: true

    # Excluded from default selects because vectors are large and almost never wanted alongside
    # ordinary reads; retrieval selects the column explicitly.
    attribute :embedding, :vector, select_by_default?: false
    attribute :embedding_dimensions, :integer, public?: true

    # Version identity of the extraction pipeline that produced the row. The value "f5-1" is the
    # current extractor/pipeline contract, also reported by the health endpoint. Bumping it is a
    # deliberate contract transition: it needs a changelog entry, refreshed contract evidence,
    # and a note in the closest architecture document. Rows written by earlier pipelines keep
    # the value they were created with.
    attribute :pipeline_version, :string, allow_nil?: false, default: "f5-1", public?: true

    # Set by erasure and redaction flows. Not public, so it never leaks into API payloads.
    attribute :deleted_at, :utc_datetime_usec
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end

defmodule Cartulary.Knowledge.Attribution do
  @moduledoc """
  Records who or what a knowledge statement is about, and how directly it was learned.

  One row ties a statement to one target — a peer or a scope — at one `level`. The level is
  the part that matters for trust: `self` means the speaker was talking about themselves,
  `hearsay` means the claim is about somebody other than the speaker (or the extractor flagged
  it second-hand), and `scope` means the claim characterises a scope rather than a person.
  Extraction already discounts a hearsay claim's confidence before it reaches governance; this
  row is the durable record of which kind it was, so collapsing the distinction would leave
  second-hand claims indistinguishable from first-hand ones.

  Rows are created only by the extraction pipeline and removed only by erasure. Nothing here is
  editable: an attribution is a fact about how a statement was obtained, and rewriting it would
  falsify the provenance trail.
  """

  use Cartulary.Resource, domain: Cartulary.Knowledge, table: "attributions"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    # Create-only, pipeline-only. There is no update action: an attribution is either right or
    # replaced by erasure plus re-extraction.
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

    # Attributions inherit the visibility of the scope the statement lives in.
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

    # "peer" or "scope"; the matching id below is set and the other stays nil.
    attribute :target_type, :string, allow_nil?: false, public?: true
    attribute :target_peer_id, :uuid, public?: true
    attribute :target_scope_id, :uuid, public?: true

    # "self", "hearsay", or "scope" — first-hand versus second-hand knowledge.
    attribute :level, :string, allow_nil?: false, public?: true
    create_timestamp :inserted_at
  end

  # One attribution per statement/target/level combination, per Account. Because one of the two
  # target columns is always NULL, and PostgreSQL treats NULLs as distinct in a unique index,
  # this identity does not by itself stop a duplicate: the pipeline looks for an existing row
  # before creating one, and that read is what makes a re-extraction idempotent.
  identities do
    identity :knowledge_target,
             [:knowledge_item_id, :target_type, :target_peer_id, :target_scope_id, :level]
  end
end

defmodule Cartulary.Knowledge.Provenance do
  @moduledoc """
  Append-only record of one source that supports a knowledge statement.

  Each row answers "where did this claim come from": the raw observation (`message_id` for a
  conversation turn, `document_version_id` for an ingested document version), the model and
  prompt versions that extracted it, and when the source event occurred. A statement supported
  by three observations has three provenance rows.

  This is what makes proportionate erasure possible. Removing one subject's contribution deletes
  or scrubs that subject's provenance rows; a statement that still has surviving provenance
  keeps living, and only a statement whose last supporting row disappears is retracted.

  Rows are written by the extraction pipeline and never updated — there is no update action.
  Correcting provenance means erasing and re-deriving it, so the source trail cannot be quietly
  rewritten after the fact.
  """

  use Cartulary.Resource, domain: Cartulary.Knowledge, table: "provenances"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    # Append-only: pipeline creates, erasure destroys, nothing updates.
    create :create_from_pipeline do
      accept [
        :knowledge_item_id,
        :scope_id,
        :source_type,
        :message_id,
        :document_version_id,
        :extracting_provider,
        :extracting_model,
        :extracting_model_version,
        :prompt_version,
        :embedding_provider,
        :embedding_model,
        :embedding_version,
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

    # "message" or "document"; exactly one of the two source ids below is populated to match.
    attribute :source_type, :string, allow_nil?: false, public?: true
    attribute :message_id, :uuid, public?: true
    attribute :document_version_id, :uuid, public?: true

    # Model and prompt identity captured at extraction time, so a later model change cannot
    # retroactively rewrite the story of how this statement was produced.
    attribute :extracting_provider, :string, public?: true
    attribute :extracting_model, :string, public?: true
    attribute :extracting_model_version, :string, public?: true
    attribute :prompt_version, :string, public?: true
    attribute :embedding_provider, :string, public?: true
    attribute :embedding_model, :string, public?: true
    attribute :embedding_version, :string, public?: true

    # No default here, unlike the statement itself: the caller must state which pipeline
    # contract version produced this evidence row.
    attribute :pipeline_version, :string, allow_nil?: false, public?: true

    # When the source event happened, which can be far earlier than when it was ingested.
    attribute :occurred_at, :utc_datetime_usec, allow_nil?: false, public?: true
    create_timestamp :inserted_at
  end
end

defmodule Cartulary.Knowledge.KnowledgeRelation do
  @moduledoc """
  A typed, directed edge between two knowledge statements.

  `kind` is an unconstrained string. The only kind written by code in this repository is
  `supersedes`, which document sync creates when a new version replaces a claim: the replacement
  points at the statement it retires. Because the old row survives in a `superseded` state, the
  pair records both what the system believes now and what it believed before, without deleting
  anything. The governance engine additionally *reads* `conflict` edges, so that a reviewer sees
  a contradiction bundled with the proposal.

  Relations are also a retrieval expansion path: after seed candidates are found, expansion
  walks these edges (in either direction) to pull in neighbouring statements. The `confidence`
  on the edge becomes that neighbour's edge score, so a weak link contributes weakly.

  Rows are create-only and pipeline-only. There is no update and no destroy action here — an
  edge that turned out to be wrong is superseded by the lifecycle of the statements it joins,
  not rewritten in place.
  """

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
    # Direction matters: for a supersession edge the source is the replacement and the target is
    # the statement being retired.
    attribute :source_knowledge_id, :uuid, allow_nil?: false, public?: true
    attribute :target_knowledge_id, :uuid, allow_nil?: false, public?: true
    attribute :kind, :string, allow_nil?: false, public?: true

    # Strength of the edge, reused as the expansion score when retrieval walks it.
    attribute :confidence, :float, allow_nil?: false, default: 1.0, public?: true
    create_timestamp :inserted_at
  end

  # One edge per ordered pair and kind, per Account, so replaying the same supersession is a
  # no-op rather than a duplicate.
  identities do
    identity :unique_relation, [:source_knowledge_id, :target_knowledge_id, :kind]
  end
end

defmodule Cartulary.Knowledge.LifecycleEvent do
  @moduledoc """
  The append-only history of every knowledge state change.

  One row per state change: which statement moved, from which state to which state, the reason
  code supplied by whoever made the decision, and when it happened. Together with the audit
  chain, this is the answer to "why is this claim active?" or "who rejected this and when?".

  Transition rows are written by the statement's `transition` action inside the same transaction
  as the state change, so history can never diverge from the current state. The extraction
  pipeline also records one event when it first proposes a statement; that row has no
  `from_state`, because there is no earlier state to leave.

  There is no update and no destroy action. If a transition was wrong, the correction is another
  transition, which appends another event — the record of the mistake stays.
  """

  use Cartulary.Resource,
    domain: Cartulary.Knowledge,
    table: "knowledge_lifecycle_events"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    # Append-only. Called from the knowledge transition change and from the extraction pipeline
    # when a statement is first proposed, never directly by a surface.
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

    # Curators, admins, internal system actors, and the pipeline may append history. Unlike the
    # curator decision itself, this check is not human-only, because automatic gate results and
    # the aging sweeper must also be able to record what they did.
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

    # The state being left. Nil on the pipeline's initial "proposed" event; the transition change
    # fills it from the pre-update row.
    attribute :from_state, :string, public?: true
    attribute :to_state, :string, allow_nil?: false, public?: true

    # A short machine-readable reason code, not free-form content. Keep statement text out of
    # it: this row is part of the content-safe evidence trail.
    attribute :reason, :string, allow_nil?: false, public?: true
    attribute :occurred_at, :utc_datetime_usec, allow_nil?: false, public?: true
    create_timestamp :inserted_at
  end
end

defmodule Cartulary.Knowledge.Projection do
  @moduledoc """
  A rebuildable context cache: a scope card, a peer profile slice, or a session summary.

  Projections exist so that assembling context for a request is a cheap read instead of a live
  retrieval pass. They are derived entirely from governed knowledge statements. Losing this
  table costs latency, never truth — the background refresh job recreates every row from the
  statements that survive.

  ## Keys and kinds

  `cache_key` is the identity of one projection within an Account, and its shape encodes the
  kind: a scope card keys on the scope id, a peer profile on scope plus peer, a session summary
  on scope plus session. The uniqueness index is Account-scoped, so two Accounts may hold the
  same key without colliding.

  ## Freshness

  `watermark` is when the content was last rebuilt; `source_ids` lists the statements it was
  built from; `delta_count` counts incremental merges since the last full compaction. When a
  statement's lifecycle changes, affected projections are marked `dirty` in the same transaction
  as the state change, and the cached copy held in memory is invalidated across nodes. Readers
  must treat `dirty` rows as unusable and fall back to live retrieval.

  ## Mistakes to avoid

  * Never treat a projection as a system of record; never write content into one that is not
    derived from statements the caller could already retrieve.
  * Never bypass the dirty flag to serve a stale card. A dirty projection may contain text from
    a statement that has since been rejected, redacted, or erased.
  """

  use Cartulary.Resource, domain: Cartulary.Knowledge, table: "projections"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    # Upsert on the Account-local cache key so a refresh either creates the projection or
    # replaces its contents; the identifying columns (scope, peer, session, kind) are set once
    # at creation and are deliberately absent from the upsert field list below.
    create :upsert_from_pipeline do
      accept [
        :cache_key,
        :scope_id,
        :peer_id,
        :session_id,
        :kind,
        :version,
        :content,
        :source_ids,
        :dirty,
        :watermark,
        :delta_count
      ]

      upsert? true
      upsert_identity :cache_key

      upsert_fields [
        :version,
        :content,
        :source_ids,
        :dirty,
        :watermark,
        :delta_count,
        :updated_at
      ]
    end

    # The "mark dirty" path. It accepts the content fields as well, but every caller in this
    # codebase only flips the flag; full rewrites go through the upsert above.
    update :refresh_from_pipeline do
      accept [:version, :content, :source_ids, :dirty, :watermark, :delta_count]
    end
  end

  policies do
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    # A projection is readable by anyone who may read its scope. Its content is assembled only
    # from statements the same authorization would have allowed.
    policy action_type(:read) do
      authorize_if {Cartulary.Policy.ScopeAccess, attribute: :scope_id}
    end

    # Only the refresh pipeline may write a cache. No human surface can hand-edit a projection,
    # because the next rebuild would silently discard the edit anyway.
    policy action([:upsert_from_pipeline, :refresh_from_pipeline]) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false

    # Identity of this projection inside the Account, e.g. a scope card key, a scope-plus-peer
    # profile key, or a scope-plus-session summary key.
    attribute :cache_key, :string, allow_nil?: false
    attribute :scope_id, :uuid, allow_nil?: false

    # Set only for the projection kinds that need them: peer profiles and session summaries.
    attribute :peer_id, :uuid, public?: true
    attribute :session_id, :uuid, public?: true
    attribute :kind, :string, allow_nil?: false, public?: true

    # Monotonic per projection; raised on every rebuild so a stale reader can detect drift.
    attribute :version, :integer, allow_nil?: false, default: 1, public?: true

    # The assembled payload. Not public: it is served through the context assembly layer, which
    # applies the caller's budget and ordering, rather than exposed as a raw resource field.
    attribute :content, :map, allow_nil?: false, default: %{}

    # Statement ids the content was built from. Incremental merges keep only entries whose
    # source id is still present, so retracted statements drop out of the cache.
    attribute :source_ids, {:array, :uuid}, allow_nil?: false, default: []

    # True once an underlying statement changed and before the rebuild ran. Readers must not
    # serve a dirty projection.
    attribute :dirty, :boolean, allow_nil?: false, default: false, public?: true

    # When the content was last rebuilt.
    attribute :watermark, :utc_datetime_usec

    # Incremental merges since the last full rebuild. The refresh job compacts fully once this
    # crosses the configured cadence, bounding how far a merged cache can drift from a clean
    # rebuild.
    attribute :delta_count, :integer, allow_nil?: false, default: 0
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  # Unique per Account: the tenant attribute is part of the generated index, so the same cache
  # key in another Account is a different row.
  identities do
    identity :cache_key, [:cache_key]
  end
end

defmodule Cartulary.Knowledge.Entity do
  @moduledoc """
  A rebuildable, pipeline-internal cache row for one resolved real-world entity.

  Background resolution scans active statements for candidate surface forms, folds the ones that
  refer to the same thing onto a single row, and remembers every spelling it has seen in
  `aliases`. Retrieval uses these rows to expand a search: two statements that mention the same
  entity become neighbours even when they share no words.

  ## This cache is invisible to callers

  Entity rows, canonical names, aliases, surface forms, and entity ids must never reach an HTTP
  response, an MCP tool result, a projection payload, or a retrieval result. Entity-based
  expansion returns *statements*, never the entity that linked them. The read action is
  restricted to the pipeline actor for exactly this reason — an ordinary authorized reader
  cannot list these rows at all, which is unusual for this codebase and deliberate.

  ## Rebuildability

  Nothing here is a system of record. `derived_from` records the statements that produced the
  row, resolution reruns from active statements, and rows that lose all their mentions are
  pruned. Erasure and logical import both recompute the cache rather than transporting it, so a
  restored Account regenerates entities under its own embedder identity.

  Unresolved or wrong entities degrade retrieval recall. They never block ingest, never change
  what a statement says, and never widen who may see it: a mention inherits visibility from its
  statement and nothing else.
  """

  use Cartulary.Resource, domain: Cartulary.Knowledge, table: "entities"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    # Upsert on canonical name plus kind so a concurrent resolution pass converges on one row
    # instead of creating a near-duplicate entity.
    create :create_from_pipeline do
      accept [
        :canonical_name,
        :kind,
        :aliases,
        :alias_embedding,
        :embedding_provider,
        :embedding_model,
        :embedding_version,
        :embedding_dimensions,
        :derived_from
      ]

      upsert? true
      upsert_identity :canonical_name_kind

      upsert_fields [
        :aliases,
        :alias_embedding,
        :embedding_provider,
        :embedding_model,
        :embedding_version,
        :embedding_dimensions,
        :derived_from,
        :updated_at
      ]
    end

    # Folding a newly seen spelling into an existing entity: widens the alias list, re-embeds the
    # combined names, and appends the contributing statement id.
    update :recompute_from_pipeline do
      accept [
        :canonical_name,
        :kind,
        :aliases,
        :alias_embedding,
        :embedding_provider,
        :embedding_model,
        :embedding_version,
        :embedding_dimensions,
        :derived_from
      ]
    end

    # Used both by subject erasure and by the pruning pass that drops entities left without any
    # mention after a rebuild.
    destroy :erase do
      require_atomic? false
    end
  end

  policies do
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    # Note that reads are pipeline-only, not scope-gated: this cache has no public surface at
    # all. Adding a route or tool that exposes it would leak names across scope boundaries,
    # because an entity spans every scope that mentioned it.
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

    # The first surface form that created the row, plus a coarse inferred kind (for example a
    # person or an organisation). Neither is authoritative; both are resolution heuristics.
    attribute :canonical_name, :string, allow_nil?: false
    attribute :kind, :string, allow_nil?: false

    # Every spelling folded onto this entity so far. Exact alias matching is the cheap first
    # resolution step, before any embedding comparison runs.
    attribute :aliases, {:array, :string}, allow_nil?: false, default: []

    # Embedding of the canonical name and aliases together, used for cosine comparison against a
    # newly seen surface form. Excluded from default selects because it is large.
    attribute :alias_embedding, :vector, select_by_default?: false

    # Pinned embedder identity for the vector above; comparisons are only meaningful within one
    # provider/model/version/dimensions tuple.
    attribute :embedding_provider, :string
    attribute :embedding_model, :string
    attribute :embedding_version, :string
    attribute :embedding_dimensions, :integer

    # Statements that contributed to this entity. The audit trail of a derived row, and the
    # reason the cache can always be rebuilt from surviving knowledge.
    attribute :derived_from, {:array, :uuid}, allow_nil?: false, default: []
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  # One row per canonical name and kind within an Account.
  identities do
    identity :canonical_name_kind, [:canonical_name, :kind]
  end
end

defmodule Cartulary.Knowledge.EntityMention do
  @moduledoc """
  A rebuildable link saying "this statement mentions this entity, spelled this way".

  Mentions are the join table that lets retrieval expand from one statement to other statements
  about the same entity. Like the entity rows themselves they are a pipeline-internal cache:
  resolution clears a scope's mentions and re-derives them from active statements, and no
  surface — HTTP, MCP, LiveView, projections, retrieval payloads — may expose the surface form
  or the entity id.

  A mention carries `scope_id` so a rebuild can work one scope at a time, but it grants no
  visibility of its own. Whoever may read the statement may learn what the statement says;
  sharing an entity with a statement in another scope never widens access to that statement.

  Rows are create-or-erase only. A changed statement produces a fresh set of mentions rather
  than an edited one, which keeps the cache consistent with the text it was derived from.
  """

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

    # Pipeline-only reads, matching the entity rows: this cache has no public surface.
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

    # Copied from the statement so a rebuild can scope its work; it is not an access grant.
    attribute :scope_id, :uuid, allow_nil?: false
    attribute :entity_id, :uuid, allow_nil?: false

    # The exact text that matched inside the statement. Content-bearing, hence never exposed.
    attribute :surface_form, :string, allow_nil?: false

    # How sure the resolver is about this link. When retrieval expands from one statement to
    # another through a shared entity, the lower of the two mention confidences becomes the
    # neighbour's edge score, so a shaky match contributes a weak candidate.
    attribute :confidence, :float, allow_nil?: false
    create_timestamp :inserted_at
  end

  # One row per statement, entity, and surface form, so re-running resolution is idempotent.
  identities do
    identity :knowledge_entity_surface, [:knowledge_item_id, :entity_id, :surface_form]
  end
end
