# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.F2TransactionalWritesAuditJobsTest do
  use Cartulary.DataCase, async: false

  alias Cartulary.Clock
  alias Cartulary.DataLayer
  alias Cartulary.Governance.Audit
  alias Cartulary.Governance.AuditEvent
  alias Cartulary.Memory
  alias Cartulary.Observations.Message
  alias Cartulary.Operations.PipelineRun
  alias Cartulary.Pipeline.Idempotency

  setup do
    original_api_key = System.get_env("OPENROUTER_API_KEY")
    original_models = Application.fetch_env!(:cartulary, :models)

    System.delete_env("OPENROUTER_API_KEY")
    Application.put_env(:cartulary, :models, Keyword.put(original_models, :api_key, nil))

    on_exit(fn ->
      if original_api_key do
        System.put_env("OPENROUTER_API_KEY", original_api_key)
      else
        System.delete_env("OPENROUTER_API_KEY")
      end

      Application.put_env(:cartulary, :models, original_models)
    end)

    :ok
  end

  test "raw observation, content-safe audit, pipeline run, and AshOban job commit together" do
    assert {:ok, message} =
             Memory.ingest_message(
               ingest_attrs("f2-commit", "commit-session", sync_extract: false)
             )

    account_id = account_id!("f2-commit")

    assert %{rows: [["message.ingested", content_hash, message_count, run_count, job_count]]} =
             Ecto.Adapters.SQL.query!(
               Repo,
               """
               SELECT audit.action,
                      audit.content_hash,
                      (SELECT count(*) FROM messages WHERE id = $1),
                      (SELECT count(*) FROM pipeline_runs
                       WHERE target_id = $1 AND kind = 'extraction'),
                      (SELECT count(*) FROM oban_jobs
                       WHERE args->>'tenant' = $2
                         AND args->>'pipeline_kind' = 'extraction')
               FROM audit_events AS audit
               WHERE audit.resource_id = $1
               """,
               [Ecto.UUID.dump!(message["id"]), account_id]
             )

    assert content_hash == Idempotency.content_hash(message["content"])
    assert message_count == 1
    assert run_count == 1
    assert job_count == 1

    assert scalar!(
             """
             SELECT count(*) FROM pipeline_runs
             WHERE account_id = $1 AND kind = 'reconciler'
             """,
             [Ecto.UUID.dump!(account_id)]
           ) == 1
  end

  test "forced failure after audit and enqueue rolls back raw write, audit, run, and job" do
    assert {:ok, _seed} =
             Memory.ingest_message(
               ingest_attrs("f2-rollback", "seed-session", sync_extract: false)
             )

    before = account_counts("f2-rollback")
    {session_id, scope_id, peer_id} = observation_ids!("f2-rollback")

    assert_raise RuntimeError, ~r/forced F2 rollback/, fn ->
      DataLayer.with_account_key("f2-rollback", fn account, actor ->
        Message
        |> Ash.Changeset.new()
        |> Ash.Changeset.set_tenant(account.id)
        |> Ash.Changeset.set_context(%{
          cartulary_actor: actor,
          private: %{f2_force_rollback?: true}
        })
        |> Ash.Changeset.for_create(:create, %{
          session_id: session_id,
          scope_id: scope_id,
          peer_id: peer_id,
          role: "user",
          content: "This observation must roll back with its audit and job.",
          occurred_at: Clock.utc_now()
        })
        |> Ash.create(actor: actor)
      end)
    end

    assert account_counts("f2-rollback") == before
  end

  test "AshOban extraction executes the ingest Reactor and marks durable processing complete" do
    assert {:ok, message} =
             Memory.ingest_message(ingest_attrs("f2-drain", "drain-session", sync_extract: false))

    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :ingest)

    assert %{rows: [[completed_at, 1, "completed"]]} =
             Ecto.Adapters.SQL.query!(
               Repo,
               """
               SELECT message.extraction_completed_at,
                      (SELECT count(*) FROM knowledge_items
                       WHERE $1 = ANY(source_message_ids)),
                      run.status
               FROM messages AS message
               JOIN pipeline_runs AS run ON run.target_id = message.id
               WHERE message.id = $1 AND run.kind = 'extraction'
               """,
               [Ecto.UUID.dump!(message["id"])]
             )

    assert %NaiveDateTime{} = completed_at
  end

  test "pipeline replay merges provenance and never duplicates knowledge or lifecycle" do
    assert {:ok, message} =
             Memory.ingest_message(ingest_attrs("f2-replay", "replay-session"))

    account_id = account_id!("f2-replay")
    before = knowledge_counts(account_id)

    assert {:ok, [_knowledge]} =
             Memory.extract_message_for_account(message["id"], account_id)

    assert {:ok, [_knowledge]} =
             Memory.extract_message_for_account(message["id"], account_id)

    assert knowledge_counts(account_id) == before
  end

  test "provider unavailability cannot prevent raw persistence and transactional enqueue" do
    models =
      :cartulary
      |> Application.fetch_env!(:models)
      |> Keyword.merge(
        api_key: "configured-but-unavailable",
        base_url: "http://127.0.0.1:1"
      )

    Application.put_env(:cartulary, :models, models)

    assert {:ok, message} =
             Memory.ingest_message(
               ingest_attrs("f2-provider-down", "provider-session", sync_extract: false)
             )

    refute Map.has_key?(message, "knowledge")

    assert scalar!(
             """
             SELECT count(*)
             FROM messages
             WHERE id = $1
               AND extraction_completed_at IS NULL
             """,
             [Ecto.UUID.dump!(message["id"])]
           ) == 1

    assert scalar!(
             "SELECT count(*) FROM pipeline_runs WHERE target_id = $1 AND kind = 'extraction'",
             [Ecto.UUID.dump!(message["id"])]
           ) == 1
  end

  test "per-Account audit events form a verifiable content-safe hash chain" do
    content = "Hash-chain evidence never stores this raw statement in audit metadata."

    assert {:ok, _message} =
             Memory.ingest_message(
               ingest_attrs("f2-audit-chain", "audit-session", content: content)
             )

    events =
      DataLayer.with_account_key(
        "f2-audit-chain",
        [role: :system, pipeline?: true],
        fn account, actor ->
          AuditEvent
          |> Ash.Query.sort(inserted_at: :asc, id: :asc)
          |> Ash.Query.set_tenant(account.id)
          |> Ash.read!(actor: actor)
        end
      )

    assert length(events) >= 4
    assert Enum.any?(events, &(&1.action == "knowledge.transitioned"))
    assert Enum.any?(events, &(&1.action == "gate_a.defer"))
    assert Enum.any?(events, &(&1.action == "gate_b.provisional"))

    events
    |> Enum.reduce(nil, fn event, previous_hash ->
      assert event.previous_hash == previous_hash
      assert event.event_hash =~ ~r/\A[0-9a-f]{64}\z/
      refute inspect(event.metadata) =~ content

      payload = %{
        account_id: event.account_id,
        category: event.category,
        action: event.action,
        resource_type: event.resource_type,
        resource_id: event.resource_id,
        content_hash: event.content_hash,
        metadata: event.metadata,
        occurred_at: DateTime.to_iso8601(event.occurred_at),
        previous_hash: event.previous_hash
      }

      assert event.event_hash == Audit.content_hash(payload)
      event.event_hash
    end)
  end

  test "F2 registers every job lane, continuation Reactor, and deterministic key family" do
    trigger_names =
      PipelineRun
      |> AshOban.Info.oban_triggers()
      |> Enum.map(& &1.name)
      |> Enum.sort()

    assert trigger_names ==
             Enum.sort([
               :answer_correlation,
               :connector_sync,
               :dream_time,
               :entity_resolution,
               :expiry,
               :extraction,
               :import_rebuild,
               :projection_refresh,
               :reconciler,
               :revalidation,
               :validation_continuation
             ])

    assert Code.ensure_loaded?(Cartulary.Pipeline.Workflows.IngestExtraction)
    assert Code.ensure_loaded?(Cartulary.Pipeline.Workflows.DreamTimeReasoning)
    assert Code.ensure_loaded?(Cartulary.Pipeline.Workflows.ValidationContinuation)
    assert Code.ensure_loaded?(Cartulary.Pipeline.Workflows.AnswerCorrelationContinuation)

    message_id = Ecto.UUID.generate()
    message_key = Idempotency.message_extraction(message_id, "content-hash")

    assert message_key ==
             Idempotency.message_extraction(message_id, "content-hash")

    assert message_key != Idempotency.document_extraction(Ecto.UUID.generate(), "content-hash")

    scope_id = Ecto.UUID.generate()
    assert Idempotency.dream_time(scope_id, 42) == Idempotency.dream_time(scope_id, 42)

    assert Idempotency.projection_refresh(scope_id, 42) !=
             Idempotency.entity_resolution(scope_id, 42)

    assert Idempotency.import_rebuild("import-1", "manifest-a") !=
             Idempotency.import_rebuild("import-1", "manifest-b")

    assert Enum.sort(Audit.categories()) ==
             Enum.sort(
               ~w(attribution configuration deletion gate governance lifecycle observation)
             )
  end

  defp ingest_attrs(account_key, session_id, overrides \\ []) do
    %{
      "account_key" => account_key,
      "session_id" => session_id,
      "scope_path" => "/f2/#{account_key}",
      "peer_key" => "#{account_key}-peer",
      "role" => "user",
      "content" => "Avery prefers concise weekly release summaries."
    }
    |> Map.merge(Map.new(overrides, fn {key, value} -> {to_string(key), value} end))
  end

  defp account_id!(account_key) do
    %{rows: [[id]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT id::text FROM accounts WHERE key = $1",
        [account_key]
      )

    id
  end

  defp observation_ids!(account_key) do
    %{rows: [[session_id, scope_id, peer_id]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT session.id::text, scope.id::text, peer.id::text
        FROM sessions AS session
        JOIN accounts AS account ON account.id = session.account_id
        JOIN scopes AS scope ON scope.id = session.scope_id
        JOIN peers AS peer ON peer.id = session.peer_id
        WHERE account.key = $1
        LIMIT 1
        """,
        [account_key]
      )

    {session_id, scope_id, peer_id}
  end

  defp account_counts(account_key) do
    account_id = account_id!(account_key)

    %{rows: [[messages, audits, runs, jobs]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT
          (SELECT count(*) FROM messages WHERE account_id = $1),
          (SELECT count(*) FROM audit_events WHERE account_id = $1),
          (SELECT count(*) FROM pipeline_runs WHERE account_id = $1),
          (SELECT count(*) FROM oban_jobs WHERE args->>'tenant' = $2)
        """,
        [Ecto.UUID.dump!(account_id), account_id]
      )

    {messages, audits, runs, jobs}
  end

  defp knowledge_counts(account_id) do
    %{rows: [[knowledge, lifecycle, attributions, provenances, audits]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT
          (SELECT count(*) FROM knowledge_items WHERE account_id = $1),
          (SELECT count(*) FROM knowledge_lifecycle_events WHERE account_id = $1),
          (SELECT count(*) FROM attributions WHERE account_id = $1),
          (SELECT count(*) FROM provenances WHERE account_id = $1),
          (SELECT count(*) FROM audit_events WHERE account_id = $1)
        """,
        [Ecto.UUID.dump!(account_id)]
      )

    {knowledge, lifecycle, attributions, provenances, audits}
  end

  defp scalar!(sql, params) do
    %{rows: [[value]]} = Ecto.Adapters.SQL.query!(Repo, sql, params)
    value
  end
end
