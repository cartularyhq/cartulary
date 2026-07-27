# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Pipeline do
  @moduledoc """
  F2 transactional pipeline boundary.

  Every enqueue creates or reuses a durable `PipelineRun`; that Ash create
  action inserts the corresponding AshOban job in the caller's transaction.
  """

  alias Cartulary.Actor
  alias Cartulary.Clock
  alias Cartulary.Operations.PipelineRun
  alias Cartulary.Pipeline.Idempotency

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
        _other -> Cartulary.Pipeline.Workflows.Maintenance
      end

    Reactor.run(reactor, %{pipeline_run: run}, %{}, async?: false)
  end

  @spec job_args(PipelineRun.t()) :: map()
  def job_args(run) do
    %{
      "idempotency_key" => run.idempotency_key,
      "pipeline_kind" => run.kind
    }
  end

  defp pipeline_actor(%Actor{} = actor), do: %{actor | role: :system, pipeline?: true}

  defp pipeline_actor(actor) do
    actor
    |> Map.put(:role, :system)
    |> Map.put(:pipeline?, true)
  end
end
