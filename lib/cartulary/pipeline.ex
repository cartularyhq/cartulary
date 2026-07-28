# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Pipeline do
  @moduledoc """
  The only supported way to schedule and run background pipeline work.

  Cartulary's pipeline is the sole writer of knowledge: agents and HTTP callers
  submit raw observations, and everything that turns an observation into
  governed knowledge happens behind this module. Nothing outside the pipeline
  may create, corroborate, or activate a knowledge row.

  ## What enqueueing actually does

  Every `enqueue_*` function creates or reuses a durable
  `Cartulary.Operations.PipelineRun` row through an Ash create action, and that
  action inserts the matching background job in the *caller's* transaction. The
  durable source write, its audit entry, and the queued work therefore commit
  together or roll back together. Never insert a job directly: that produces
  jobs for state which was never committed, and committed state that nothing
  will ever process.

  ## Idempotency is mandatory, not optional

  Each run carries a deterministic `idempotency_key` built from a key-family
  name plus the immutable identity of the thing being processed — a message id
  with its content hash, a document version with its content hash, a scope with
  a watermark. The create action upserts on that key, so a retry, a reconciler
  sweep, and a duplicate event all converge on one row instead of processing
  the same input twice. A new lane must add a key of the same shape before it
  can be enqueued; a key that varies per call (a timestamp taken at enqueue
  time, a random id) silently reintroduces duplicate processing.

  ## Content safety

  The attributes passed here — `payload` in particular — and the job arguments
  produced by `job_args/1` carry hashes, ids, watermarks, and short labels such
  as a lane or decision name. Raw message text, extracted statements, connector
  cursors, document bytes, and secrets must never be copied into them: both are
  durable, both are visible to operators, and neither is reached by erasure.

  ## Actor handling

  Every enqueue rewrites the caller's actor into a system pipeline actor so the
  run's internal-only create policy admits it. The rewrite is on a copy; the
  caller keeps its real role for everything else it does in the request.
  """

  alias Cartulary.Actor
  alias Cartulary.Clock
  alias Cartulary.Operations.PipelineRun
  alias Cartulary.Pipeline.Idempotency

  # Lane name to the Ash create action that upserts the run and inserts its job.
  # The lane string is the public vocabulary used by callers and stored on the
  # row; the action name is private wiring. Adding a lane requires a matching
  # action, an Oban trigger, and a deterministic key family.
  @enqueue_actions %{
    "extraction" => :enqueue_extraction,
    "dream_time" => :enqueue_dream_time,
    "revalidation" => :enqueue_revalidation,
    "expiry" => :enqueue_expiry,
    "projection_refresh" => :enqueue_projection_refresh,
    "connector_sync" => :enqueue_connector_sync,
    "import_rebuild" => :enqueue_import_rebuild,
    "reconciler" => :enqueue_reconciler,
    "entity_resolution" => :enqueue_entity_resolution,
    "validation_continuation" => :enqueue_validation_continuation,
    "answer_correlation" => :enqueue_answer_correlation
  }

  @doc """
  Schedules extraction of one raw message.

  Call this from inside the transaction that persisted the message, so the
  observation and the job commit together. The replay key combines the message
  id with its content hash: re-enqueueing the same message returns the existing
  run, while a message whose content differs is a different unit of work.

  Only the content hash travels in the payload — never the message text.

  Returns `{:ok, run}` or `{:error, reason}`.
  """
  @spec enqueue_message_extraction(struct(), map()) ::
          {:ok, PipelineRun.t()} | {:error, term()}
  def enqueue_message_extraction(message, actor) do
    enqueue(
      "extraction",
      message.account_id,
      %{
        scope_id: message.scope_id,
        target_type: "message",
        target_id: message.id,
        idempotency_key: Idempotency.message_extraction(message.id, message.content_hash),
        payload: %{"content_hash" => message.content_hash}
      },
      actor
    )
  end

  @doc """
  Schedules extraction of one immutable document version.

  Document versions are append-only, so the version id plus its content hash is
  a stable replay key: re-uploading identical bytes reuses the run, and changed
  bytes produce a new version with its own run. The payload carries the content
  hash only — never the document bytes or the extracted text.

  Returns `{:ok, run}` or `{:error, reason}`.
  """
  @spec enqueue_document_extraction(struct(), map()) ::
          {:ok, PipelineRun.t()} | {:error, term()}
  def enqueue_document_extraction(version, actor) do
    enqueue(
      "extraction",
      version.account_id,
      %{
        scope_id: version.scope_id,
        target_type: "document_version",
        target_id: version.id,
        idempotency_key: Idempotency.document_extraction(version.id, version.content_hash),
        payload: %{"content_hash" => version.content_hash}
      },
      actor
    )
  end

  @doc """
  Schedules one sync pass for a connector.

  The replay key combines the connector id, its current cursor, and the sync
  slot it is due for, so repeatedly asking for the same pass coalesces onto one
  run while the *next* pass — after the cursor advances — is distinct work.

  A connector cursor may name remote paths, folders, or query parameters, so it
  is hashed rather than stored: the payload carries `cursor_hash` only.

  Returns `{:ok, run}` or `{:error, reason}`.
  """
  @spec enqueue_connector_sync(struct(), map()) ::
          {:ok, PipelineRun.t()} | {:error, term()}
  def enqueue_connector_sync(connector, actor) do
    # Falls back through due time, last completion, and creation so a connector
    # that has never run still produces a stable slot rather than a moving one.
    scheduled_at = connector.next_sync_at || connector.last_synced_at || connector.inserted_at

    enqueue(
      "connector_sync",
      connector.account_id,
      %{
        scope_id: connector.scope_id,
        target_type: "connector_config",
        target_id: connector.id,
        idempotency_key: Idempotency.connector_sync(connector.id, connector.cursor, scheduled_at),
        payload: %{
          "cursor_hash" =>
            connector.cursor
            |> :erlang.term_to_binary([:deterministic])
            |> Idempotency.content_hash()
        }
      },
      actor
    )
  end

  @doc """
  Schedules a reconciliation sweep for one Account.

  The sweep finds durable observations that never completed processing and
  re-enqueues them. `watermark` names the sweep: two callers passing the same
  watermark share one run, while a later watermark is a new sweep. Passing
  `nil` stamps the current time, which makes each call a distinct sweep — pass
  an explicit watermark when several callers should coalesce.

  Returns `{:ok, run}` or `{:error, reason}`.
  """
  @spec enqueue_reconciler(Ecto.UUID.t(), map(), term()) ::
          {:ok, PipelineRun.t()} | {:error, term()}
  def enqueue_reconciler(account_id, actor, watermark \\ nil) do
    watermark = watermark || DateTime.to_iso8601(Clock.utc_now())

    enqueue(
      "reconciler",
      account_id,
      %{
        target_type: "account",
        target_id: account_id,
        idempotency_key: Idempotency.reconciler(account_id, watermark),
        payload: %{"watermark" => to_string(watermark)}
      },
      actor
    )
  end

  @doc """
  Generic enqueue for a named lane.

  `kind` must be one of the known lane names; an unknown lane raises
  `KeyError`, because silently dropping work would be worse than crashing the
  caller's transaction. `attrs` must include a deterministic `idempotency_key`
  and may include `scope_id`, `target_type`, `target_id`, and a content-free
  `payload`.

  The tenant is set explicitly from `account_id` rather than inferred, so a run
  can never be created against another Account. The caller's actor is copied
  into a system pipeline actor to satisfy the run's internal-only write policy.

  Returns `{:ok, run}` or `{:error, reason}`. Because the create action inserts
  the background job inside the same transaction, an error here leaves no
  orphaned job behind.
  """
  @spec enqueue(String.t(), Ecto.UUID.t(), map(), map()) ::
          {:ok, PipelineRun.t()} | {:error, term()}
  def enqueue(kind, account_id, attrs, actor)
      when is_binary(kind) and is_binary(account_id) and is_map(attrs) do
    action = Map.fetch!(@enqueue_actions, kind)
    actor = pipeline_actor(actor)

    PipelineRun
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_tenant(account_id)
    |> Ash.Changeset.set_context(%{cartulary_actor: actor})
    |> Ash.Changeset.for_create(action, attrs)
    |> Ash.create(actor: actor)
  end

  @doc """
  Runs the workflow for a durable run row.

  This is the body of the background job: it selects the workflow for the run's
  lane and executes it. Unknown lanes fall through to the maintenance workflow
  rather than crashing, so an older queued row from a previous release still
  completes as a durable continuation instead of failing forever.

  Execution is deliberately synchronous (`async? false`), so every step runs in
  the job's own process. Account isolation comes from transaction-local
  PostgreSQL settings that each lane installs when it opens its own
  Account-scoped transaction; a step running in another process would be on a
  different connection, outside that transaction, and would lose the scoping.

  Returns the workflow's `{:ok, result}` or `{:error, reason}`. An error leaves
  the row eligible for retry, which is safe precisely because every lane is
  keyed and replay-safe.
  """
  @spec execute(PipelineRun.t()) :: {:ok, term()} | {:error, term()}
  def execute(%PipelineRun{kind: kind} = run) do
    reactor =
      case kind do
        "extraction" -> Cartulary.Pipeline.Workflows.IngestExtraction
        "dream_time" -> Cartulary.Pipeline.Workflows.DreamTimeReasoning
        "entity_resolution" -> Cartulary.Pipeline.Workflows.DreamTimeReasoning
        "projection_refresh" -> Cartulary.Pipeline.Workflows.DreamTimeReasoning
        "validation_continuation" -> Cartulary.Pipeline.Workflows.ValidationContinuation
        "answer_correlation" -> Cartulary.Pipeline.Workflows.AnswerCorrelationContinuation
        "connector_sync" -> Cartulary.Pipeline.Workflows.Maintenance
        _other -> Cartulary.Pipeline.Workflows.Maintenance
      end

    Reactor.run(reactor, %{pipeline_run: run}, %{}, async?: false)
  end

  @doc """
  Builds the extra arguments copied onto a background job.

  Deliberately minimal: the replay key and the lane name, nothing else. Job
  arguments are durable and visible to anyone inspecting the queue, so content,
  payloads, and secrets must never be added here. Everything a lane needs is
  read from the run row at execution time.
  """
  @spec job_args(PipelineRun.t()) :: map()
  def job_args(run) do
    %{
      "idempotency_key" => run.idempotency_key,
      "pipeline_kind" => run.kind
    }
  end

  # Both clauses build a copy. Enqueueing is an internal capability, so the run
  # resource only admits the `:system` role or the pipeline flag; the caller's
  # own role is never mutated, and the copy keeps the caller's `account_id`,
  # which the run's policy still compares against the row.
  defp pipeline_actor(%Actor{} = actor), do: %{actor | role: :system, pipeline?: true}

  defp pipeline_actor(actor) do
    actor
    |> Map.put(:role, :system)
    |> Map.put(:pipeline?, true)
  end
end
