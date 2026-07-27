# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Operations do
  @moduledoc "Ash domain for append-only usage and durable pipeline execution state."

  use Ash.Domain

  resources do
    resource Cartulary.Operations.UsageEvent
    resource Cartulary.Operations.PipelineRun
  end
end

defmodule Cartulary.Operations.UsageEvent do
  @moduledoc false

  use Cartulary.Resource, domain: Cartulary.Operations, table: "usage_events"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    create :record do
      accept [
        :scope_id,
        :peer_id,
        :operation,
        :model_role,
        :model_name,
        :input_tokens,
        :output_tokens,
        :duration_ms,
        :metadata,
        :occurred_at
      ]
    end
  end

  policies do
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    policy action(:record) do
      authorize_if {Cartulary.Policy.RoleIn, roles: [:system]}
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    policy action_type(:read) do
      authorize_if {Cartulary.Policy.RoleIn, roles: [:account_admin, :system]}
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :scope_id, :uuid
    attribute :peer_id, :uuid
    attribute :operation, :string, allow_nil?: false, public?: true
    attribute :model_role, :string, public?: true
    attribute :model_name, :string, public?: true
    attribute :input_tokens, :integer, allow_nil?: false, default: 0, public?: true
    attribute :output_tokens, :integer, allow_nil?: false, default: 0, public?: true
    attribute :duration_ms, :integer, allow_nil?: false, default: 0, public?: true
    attribute :metadata, :map, allow_nil?: false, default: %{}
    attribute :occurred_at, :utc_datetime_usec, allow_nil?: false, public?: true
    create_timestamp :inserted_at
  end
end

defmodule Cartulary.Operations.PipelineRun do
  @moduledoc """
  Durable idempotency and reconciliation record for every F2 pipeline lane.

  The record is authoritative processing state; AshOban jobs are the
  transactional execution mechanism. A unique Account/key identity makes
  re-enqueue and reconciliation safe.
  """

  use Cartulary.Resource,
    domain: Cartulary.Operations,
    table: "pipeline_runs",
    extensions: [AshOban]

  import AshOban.Changes.BuiltinChanges

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    read :read do
      primary? true

      pagination do
        keyset? true
      end
    end

    create :enqueue_extraction do
      accept [:scope_id, :target_type, :target_id, :idempotency_key, :payload]
      upsert? true
      upsert_identity :idempotency_key
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

    update :execute do
      require_atomic? false
      change Cartulary.Pipeline.Changes.ExecuteRun
    end

    update :mark_failed do
      argument :error, :term, allow_nil?: false
      require_atomic? false
      change Cartulary.Pipeline.Changes.MarkRunFailed
    end
  end

  policies do
    bypass AshOban.Checks.AshObanInteraction do
      authorize_if always()
    end

    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    policy action_type([:create, :update]) do
      authorize_if {Cartulary.Policy.RoleIn, roles: [:system]}
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    policy action_type(:read) do
      authorize_if {Cartulary.Policy.RoleIn, roles: [:account_admin, :system]}
      authorize_if actor_attribute_equals(:pipeline?, true)
    end
  end

  oban do
    use_tenant_from_record?(true)
    shared_context([:job])

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
    attribute :account_id, :uuid, allow_nil?: false
    attribute :scope_id, :uuid
    attribute :kind, :string, allow_nil?: false, public?: true
    attribute :target_type, :string, allow_nil?: false, public?: true
    attribute :target_id, :uuid
    attribute :idempotency_key, :string, allow_nil?: false, public?: true
    attribute :payload, :map, allow_nil?: false, default: %{}
    attribute :status, :string, allow_nil?: false, default: "pending", public?: true
    attribute :attempt_count, :integer, allow_nil?: false, default: 0, public?: true
    attribute :processed_at, :utc_datetime_usec, public?: true
    attribute :last_error_class, :string, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :idempotency_key, [:idempotency_key]
  end
end
