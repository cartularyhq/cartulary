# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Operations do
  @moduledoc """
  Ash domain holding the durable operational record of what the system did.

  Two resources live here and they are deliberately different in kind:

    * `Cartulary.Operations.UsageEvent` — the append-only ledger of metered
      work, one row per HTTP request or model call. It is the exact record that
      budgets, cost estimates, and operator summaries are computed from.
    * `Cartulary.Operations.PipelineRun` — the durable processing state of one
      unit of background work, and the row that makes re-enqueueing safe.

  Neither resource stores memory content. Operators and Account administrators
  read both, so nothing written through this domain may carry message text,
  statements, prompts, questions, answers, document bytes, connector cursors,
  credentials, or secrets.
  """

  use Ash.Domain

  resources do
    resource Cartulary.Operations.UsageEvent
    resource Cartulary.Operations.PipelineRun
  end
end

defmodule Cartulary.Operations.UsageEvent do
  @moduledoc """
  Append-only ledger of exactly what an Account consumed.

  One row is one metered call: an authenticated HTTP request, recorded when its
  response is sent, or a single model invocation, recorded by the one durable
  model-usage emission point. Rows are never updated or deleted — the resource
  declares no update or destroy action — because a ledger whose past can be
  rewritten is not evidence.

  ## Exact ledger versus rebuildable counters

  This table is the system of record for usage. The in-memory daily counters
  used for cheap admission decisions are a rebuildable cache fed by the same
  emissions; losing them costs the node today's running totals and nothing
  else. Do not invert that relationship by treating a counter as authoritative
  or by skipping the ledger write to save a round trip.

  ## Content safety

  Account administrators can read these rows through the operator summary, so
  a row must stay content-safe. Identifiers, counts, durations, model
  provenance, a coarse operation name, and an `ok`/`error` status are allowed.
  Request or response bodies, message text, statements, prompts, questions,
  answers, and credentials are not. Writers reduce `metadata` to a reviewed key
  allowlist before it reaches the create action; widening that allowlist is a
  disclosure decision.

  ## Provenance columns are always populated

  Provider, model, version, prompt, and pipeline identity are non-null even for
  calls that involve no model at all. The HTTP writer fills them with literal
  placeholder strings and an `"edge"` role rather than leaving them empty, so
  every row can be grouped by role without a null check, and so a row can never
  hide which model configuration produced it.
  """

  use Cartulary.Resource, domain: Cartulary.Operations, table: "usage_events"

  # Rows belong to exactly one Account. Attribute multitenancy makes the tenant
  # a required part of every read and write, so a caller that forgets to set it
  # gets an error rather than another Account's usage.
  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    # There is deliberately no update or destroy action: append-only is what
    # makes a past billing period reconstructible.
    defaults [:read]

    create :record do
      accept [
        :call_id,
        :scope_id,
        :peer_id,
        :operation,
        :model_role,
        :provider,
        :model_name,
        :model_version,
        :prompt_version,
        :pipeline_version,
        :input_tokens,
        :output_tokens,
        :embedding_tokens,
        :duration_ms,
        :status,
        :metadata,
        :occurred_at
      ]

      # Exactly two outcomes are meaningful for cost and error-rate reporting.
      # Anything finer belongs in the metadata allowlist, not in this column,
      # because summaries group on it.
      validate attribute_in(:status, ~w(ok error))
    end
  end

  policies do
    # Applies to every action, including reads: an actor only ever sees rows
    # belonging to its own Account.
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    # Writing the ledger is internal. External callers cause rows to appear by
    # making requests, but must never author one directly — a caller that could
    # write its own usage rows could understate what it consumed.
    policy action(:record) do
      authorize_if {Cartulary.Policy.RoleIn, roles: [:system]}
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    # Totals span the whole Account rather than one scope, so reading them is an
    # administrator capability; ordinary members and readers get nothing.
    policy action_type(:read) do
      authorize_if {Cartulary.Policy.RoleIn, roles: [:account_admin, :system]}
    end
  end

  attributes do
    uuid_primary_key :id

    # Tenant column. Not public: it is derived from the authenticated identity,
    # never accepted from a request.
    attribute :account_id, :uuid, allow_nil?: false

    # Caller-generated id for one emission. The identity below turns an
    # accidental double emission into a constraint error instead of a silent
    # double charge.
    attribute :call_id, :uuid, allow_nil?: false, public?: true

    # Both nullable: not every metered call happens inside a scope, and internal
    # work has no calling peer.
    attribute :scope_id, :uuid
    attribute :peer_id, :uuid

    # Coarse operation name such as "api.ingest" or a model operation. Keep the
    # cardinality bounded and free of record ids; this column is grouped on and
    # is visible to operators.
    attribute :operation, :string, allow_nil?: false, public?: true
    # Full model provenance, so a recorded cost can always be attributed to the
    # exact configuration that produced it. Non-model rows carry placeholders
    # rather than nulls.
    attribute :model_role, :string, allow_nil?: false, public?: true
    attribute :provider, :string, allow_nil?: false, public?: true
    attribute :model_name, :string, allow_nil?: false, public?: true
    attribute :model_version, :string, allow_nil?: false, public?: true
    attribute :prompt_version, :string, allow_nil?: false, public?: true
    attribute :pipeline_version, :string, allow_nil?: false, public?: true

    # Token counts default to zero so that rows for non-model work still sum
    # cleanly alongside model rows.
    attribute :input_tokens, :integer, allow_nil?: false, default: 0, public?: true
    attribute :output_tokens, :integer, allow_nil?: false, default: 0, public?: true
    attribute :embedding_tokens, :integer, allow_nil?: false, default: 0, public?: true
    attribute :duration_ms, :integer, allow_nil?: false, default: 0, public?: true

    attribute :status, :string, allow_nil?: false, default: "ok", public?: true

    # Not public. Writers pass only allowlisted, content-free keys (counts,
    # error classes, HTTP status); everything else is dropped before it arrives.
    attribute :metadata, :map, allow_nil?: false, default: %{}

    # When the metered call happened, supplied by the writer. Distinct from the
    # insert timestamp, which is only when the row landed in the table.
    attribute :occurred_at, :utc_datetime_usec, allow_nil?: false, public?: true
    create_timestamp :inserted_at
  end

  identities do
    # Backed by a unique index. Because the resource is tenant-scoped, the index
    # covers (account_id, call_id): a retry that reuses a call id within the
    # Account is rejected rather than counted twice.
    identity :call_id, [:call_id]
  end
end

defmodule Cartulary.Operations.PipelineRun do
  @moduledoc """
  Durable processing state for one unit of background pipeline work.

  The row, not the queued job, is authoritative. A job is only the mechanism
  that executes the row's work; the row records which lane it belongs to, what
  it targets, how many attempts it has taken, and how it ended. That inversion
  is what makes the pipeline replay-safe: a lost, duplicated, or manually
  re-enqueued job cannot lose or duplicate work.

  ## Idempotency

  Every `enqueue_*` action upserts on `idempotency_key`, a deterministic string
  built from the lane plus the immutable identity of the thing being processed
  — a message id with its content hash, a document version, a scope with a
  watermark. Because the conflict target rewrites nothing but the key itself,
  a second enqueue of the same work returns the existing row untouched and its
  status, attempt count, and error class survive.

  Never add a mutable attribute to that upsert set. Doing so would let a
  duplicate enqueue reset a run that is already executing or already finished,
  which is exactly the double-processing the key exists to prevent.

  ## Transaction boundary

  Enqueueing runs inside the caller's transaction: creating the row also
  inserts the background job, so the durable source write, its audit entry, and
  the queued work either all commit or all roll back. Nothing may enqueue
  pipeline work by inserting a job directly — that would produce jobs for state
  that was never committed, and committed state with no job to process it.

  ## Content safety

  `payload` and the job arguments carry replay keys, hashes, and identifiers
  only. Message content, extracted text, statements, connector cursors, and
  secrets must never be copied into them: both outlive the request and are
  visible to operators. Failures likewise record an error class, never an error
  message, since messages routinely embed the values that caused them.
  """

  use Cartulary.Resource,
    domain: Cartulary.Operations,
    table: "pipeline_runs",
    extensions: [AshOban]

  import AshOban.Changes.BuiltinChanges

  # Runs belong to exactly one Account, and the background job inherits that
  # tenant from the record, so executing work can never cross Accounts.
  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    # Keyset pagination is not optional here: AshOban streams the trigger's
    # read action, and it refuses at compile time to use one without it.
    read :read do
      primary? true

      pagination do
        keyset? true
      end
    end

    # One enqueue action per lane. They are identical apart from the lane name
    # they stamp and the trigger they fire, and each one follows the same
    # pattern: upsert on the deterministic replay key, rewrite nothing but that
    # key on conflict, then insert the job in the same transaction. Adding a
    # lane means repeating the pattern exactly, self-referential upsert set and
    # all.
    create :enqueue_extraction do
      accept [:scope_id, :target_type, :target_id, :idempotency_key, :payload]
      upsert? true
      upsert_identity :idempotency_key
      # Deliberately a no-op update: re-enqueueing must not disturb the state of
      # a run that already exists.
      upsert_fields [:idempotency_key]
      change set_attribute(:kind, "extraction")
      change run_oban_trigger(:extraction)
    end

    create :enqueue_dream_time do
      accept [:scope_id, :target_type, :target_id, :idempotency_key, :payload]
      upsert? true
      upsert_identity :idempotency_key
      upsert_fields [:idempotency_key]
      change set_attribute(:kind, "dream_time")
      change run_oban_trigger(:dream_time)
    end

    create :enqueue_revalidation do
      accept [:scope_id, :target_type, :target_id, :idempotency_key, :payload]
      upsert? true
      upsert_identity :idempotency_key
      upsert_fields [:idempotency_key]
      change set_attribute(:kind, "revalidation")
      change run_oban_trigger(:revalidation)
    end

    create :enqueue_expiry do
      accept [:scope_id, :target_type, :target_id, :idempotency_key, :payload]
      upsert? true
      upsert_identity :idempotency_key
      upsert_fields [:idempotency_key]
      change set_attribute(:kind, "expiry")
      change run_oban_trigger(:expiry)
    end

    create :enqueue_projection_refresh do
      accept [:scope_id, :target_type, :target_id, :idempotency_key, :payload]
      upsert? true
      upsert_identity :idempotency_key
      upsert_fields [:idempotency_key]
      change set_attribute(:kind, "projection_refresh")
      change run_oban_trigger(:projection_refresh)
    end

    create :enqueue_connector_sync do
      accept [:scope_id, :target_type, :target_id, :idempotency_key, :payload]
      upsert? true
      upsert_identity :idempotency_key
      upsert_fields [:idempotency_key]
      change set_attribute(:kind, "connector_sync")
      change run_oban_trigger(:connector_sync)
    end

    create :enqueue_import_rebuild do
      accept [:scope_id, :target_type, :target_id, :idempotency_key, :payload]
      upsert? true
      upsert_identity :idempotency_key
      upsert_fields [:idempotency_key]
      change set_attribute(:kind, "import_rebuild")
      change run_oban_trigger(:import_rebuild)
    end

    create :enqueue_reconciler do
      accept [:scope_id, :target_type, :target_id, :idempotency_key, :payload]
      upsert? true
      upsert_identity :idempotency_key
      upsert_fields [:idempotency_key]
      change set_attribute(:kind, "reconciler")
      change run_oban_trigger(:reconciler)
    end

    create :enqueue_entity_resolution do
      accept [:scope_id, :target_type, :target_id, :idempotency_key, :payload]
      upsert? true
      upsert_identity :idempotency_key
      upsert_fields [:idempotency_key]
      change set_attribute(:kind, "entity_resolution")
      change run_oban_trigger(:entity_resolution)
    end

    create :enqueue_validation_continuation do
      accept [:scope_id, :target_type, :target_id, :idempotency_key, :payload]
      upsert? true
      upsert_identity :idempotency_key
      upsert_fields [:idempotency_key]
      change set_attribute(:kind, "validation_continuation")
      change run_oban_trigger(:validation_continuation)
    end

    create :enqueue_answer_correlation do
      accept [:scope_id, :target_type, :target_id, :idempotency_key, :payload]
      upsert? true
      upsert_identity :idempotency_key
      upsert_fields [:idempotency_key]
      change set_attribute(:kind, "answer_correlation")
      change run_oban_trigger(:answer_correlation)
    end

    # The job body. It runs the lane's workflow and then records the outcome on
    # this row. `transaction? false` is required, not incidental: the workflow
    # opens and commits its own transactions (raw writes, governance decisions,
    # projection rebuilds), and wrapping all of that in one long-lived
    # transaction would hold locks for the entire duration of the work.
    update :execute do
      transaction? false
      require_atomic? false
      change Cartulary.Pipeline.Changes.ExecuteRun
    end

    # Failure path invoked when the job errors. It stores only a classification
    # of the error and bumps the attempt count, leaving the row eligible for a
    # later retry or reconciliation sweep.
    update :mark_failed do
      argument :error, :term, allow_nil?: false
      require_atomic? false
      change Cartulary.Pipeline.Changes.MarkRunFailed
    end
  end

  policies do
    # Background jobs execute outside any request and therefore carry no
    # authenticated actor. The bypass admits the job runner itself; the tenant
    # still comes from the record, so this widens who may act, not on what.
    bypass AshOban.Checks.AshObanInteraction do
      authorize_if always()
    end

    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    # Enqueueing and completing runs is internal only. An external caller must
    # never be able to schedule, replay, or mark pipeline work.
    policy action_type([:create, :update]) do
      authorize_if {Cartulary.Policy.RoleIn, roles: [:system]}
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    # Reading queue state is an operator or internal capability; ordinary
    # members and readers cannot enumerate what an Account is processing.
    policy action_type(:read) do
      authorize_if {Cartulary.Policy.RoleIn, roles: [:account_admin, :system]}
      authorize_if actor_attribute_equals(:pipeline?, true)
    end
  end

  oban do
    # The executing job adopts the Account of the row it processes, so tenancy
    # survives the hop from request to background worker.
    use_tenant_from_record?(true)
    shared_context([:job])

    # One trigger per lane. Related lanes share a queue — revalidation and
    # expiry on `:lifecycle`, projection refresh and entity resolution on
    # `:projection`, validation continuation and answer correlation on
    # `:governance` — so a queue's concurrency is shared by the lanes on it.
    # Every trigger repeats the same contract:
    #
    #   * `where` claims only rows of its own lane that are pending or failed,
    #     so a completed run is never re-executed.
    #   * `scheduler_cron(false)` means no polling scheduler; work is inserted
    #     by the enqueue action, in the caller's transaction.
    #   * `trigger_once?(true)` adds completed to the job's uniqueness states,
    #     so a row whose job is queued, running, or already finished does not
    #     get a second job.
    #   * `max_attempts(5)` bounds retries; after the last attempt Oban
    #     discards the job rather than retrying forever, and the row is left in
    #     whatever state `on_error` recorded.
    #   * `on_error(:mark_failed)` records the error class on the row.
    #   * `extra_args` copies only the replay key and lane name into the job,
    #     keeping content out of Oban's durable arguments.
    triggers do
      trigger :extraction do
        action :execute
        where expr(kind == "extraction" and status in ["pending", "failed"])
        queue(:ingest)
        scheduler_cron(false)
        max_attempts(5)
        trigger_once?(true)
        on_error(:mark_failed)
        worker_module_name(Cartulary.Pipeline.Workers.Extraction)
        scheduler_module_name(Cartulary.Pipeline.Schedulers.Extraction)
        extra_args(&Cartulary.Pipeline.job_args/1)
      end

      trigger :dream_time do
        action :execute
        where expr(kind == "dream_time" and status in ["pending", "failed"])
        queue(:dream)
        scheduler_cron(false)
        max_attempts(5)
        trigger_once?(true)
        on_error(:mark_failed)
        worker_module_name(Cartulary.Pipeline.Workers.DreamTime)
        scheduler_module_name(Cartulary.Pipeline.Schedulers.DreamTime)
        extra_args(&Cartulary.Pipeline.job_args/1)
      end

      trigger :revalidation do
        action :execute
        where expr(kind == "revalidation" and status in ["pending", "failed"])
        queue(:lifecycle)
        scheduler_cron(false)
        max_attempts(5)
        trigger_once?(true)
        on_error(:mark_failed)
        worker_module_name(Cartulary.Pipeline.Workers.Revalidation)
        scheduler_module_name(Cartulary.Pipeline.Schedulers.Revalidation)
        extra_args(&Cartulary.Pipeline.job_args/1)
      end

      trigger :expiry do
        action :execute
        where expr(kind == "expiry" and status in ["pending", "failed"])
        queue(:lifecycle)
        scheduler_cron(false)
        max_attempts(5)
        trigger_once?(true)
        on_error(:mark_failed)
        worker_module_name(Cartulary.Pipeline.Workers.Expiry)
        scheduler_module_name(Cartulary.Pipeline.Schedulers.Expiry)
        extra_args(&Cartulary.Pipeline.job_args/1)
      end

      trigger :projection_refresh do
        action :execute
        where expr(kind == "projection_refresh" and status in ["pending", "failed"])
        queue(:projection)
        scheduler_cron(false)
        max_attempts(5)
        trigger_once?(true)
        on_error(:mark_failed)
        worker_module_name(Cartulary.Pipeline.Workers.ProjectionRefresh)
        scheduler_module_name(Cartulary.Pipeline.Schedulers.ProjectionRefresh)
        extra_args(&Cartulary.Pipeline.job_args/1)
      end

      trigger :connector_sync do
        action :execute
        where expr(kind == "connector_sync" and status in ["pending", "failed"])
        queue(:connector)
        scheduler_cron(false)
        max_attempts(5)
        trigger_once?(true)
        on_error(:mark_failed)
        worker_module_name(Cartulary.Pipeline.Workers.ConnectorSync)
        scheduler_module_name(Cartulary.Pipeline.Schedulers.ConnectorSync)
        extra_args(&Cartulary.Pipeline.job_args/1)
      end

      trigger :import_rebuild do
        action :execute
        where expr(kind == "import_rebuild" and status in ["pending", "failed"])
        queue(:portability)
        scheduler_cron(false)
        max_attempts(5)
        trigger_once?(true)
        on_error(:mark_failed)
        worker_module_name(Cartulary.Pipeline.Workers.ImportRebuild)
        scheduler_module_name(Cartulary.Pipeline.Schedulers.ImportRebuild)
        extra_args(&Cartulary.Pipeline.job_args/1)
      end

      trigger :reconciler do
        action :execute
        where expr(kind == "reconciler" and status in ["pending", "failed"])
        queue(:reconciler)
        scheduler_cron(false)
        max_attempts(5)
        trigger_once?(true)
        on_error(:mark_failed)
        worker_module_name(Cartulary.Pipeline.Workers.Reconciler)
        scheduler_module_name(Cartulary.Pipeline.Schedulers.Reconciler)
        extra_args(&Cartulary.Pipeline.job_args/1)
      end

      trigger :entity_resolution do
        action :execute
        where expr(kind == "entity_resolution" and status in ["pending", "failed"])
        queue(:projection)
        scheduler_cron(false)
        max_attempts(5)
        trigger_once?(true)
        on_error(:mark_failed)
        worker_module_name(Cartulary.Pipeline.Workers.EntityResolution)
        scheduler_module_name(Cartulary.Pipeline.Schedulers.EntityResolution)
        extra_args(&Cartulary.Pipeline.job_args/1)
      end

      trigger :validation_continuation do
        action :execute
        where expr(kind == "validation_continuation" and status in ["pending", "failed"])
        queue(:governance)
        scheduler_cron(false)
        max_attempts(5)
        trigger_once?(true)
        on_error(:mark_failed)
        worker_module_name(Cartulary.Pipeline.Workers.ValidationContinuation)
        scheduler_module_name(Cartulary.Pipeline.Schedulers.ValidationContinuation)
        extra_args(&Cartulary.Pipeline.job_args/1)
      end

      trigger :answer_correlation do
        action :execute
        where expr(kind == "answer_correlation" and status in ["pending", "failed"])
        queue(:governance)
        scheduler_cron(false)
        max_attempts(5)
        trigger_once?(true)
        on_error(:mark_failed)
        worker_module_name(Cartulary.Pipeline.Workers.AnswerCorrelation)
        scheduler_module_name(Cartulary.Pipeline.Schedulers.AnswerCorrelation)
        extra_args(&Cartulary.Pipeline.job_args/1)
      end
    end
  end

  attributes do
    uuid_primary_key :id

    # Tenant column, derived from the record that caused the work.
    attribute :account_id, :uuid, allow_nil?: false

    # Nullable: Account-wide lanes such as reconciliation have no single scope.
    attribute :scope_id, :uuid

    # Lane name. Set by the enqueue action rather than accepted from the caller,
    # so a run can never be filed under a lane it will not be executed by.
    attribute :kind, :string, allow_nil?: false, public?: true

    # What the run operates on: the kind of record and its id.
    attribute :target_type, :string, allow_nil?: false, public?: true
    attribute :target_id, :uuid

    # The deterministic replay key. Recomputing it from the same immutable
    # source identity must yield the same string, or replay protection breaks.
    attribute :idempotency_key, :string, allow_nil?: false, public?: true

    # Replay hints only — hashes and watermarks. Never content, never cursors.
    attribute :payload, :map, allow_nil?: false, default: %{}

    attribute :status, :string, allow_nil?: false, default: "pending", public?: true
    attribute :attempt_count, :integer, allow_nil?: false, default: 0, public?: true
    attribute :processed_at, :utc_datetime_usec, public?: true

    # A classification such as an exception module name, never a message.
    # Error messages routinely quote the content that caused them.
    attribute :last_error_class, :string, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    # Backed by a unique index over (account_id, idempotency_key), since the
    # resource is tenant-scoped. This constraint is the replay guarantee: two
    # concurrent enqueues of the same work resolve to one row.
    identity :idempotency_key, [:idempotency_key]
  end
end
