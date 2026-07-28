# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.F5ModelLayerStructuredExtractionTest do
  use Cartulary.DataCase, async: false

  alias Cartulary.DataLayer
  alias Cartulary.Memory
  alias Cartulary.Model
  alias Cartulary.Model.CassetteProvider
  alias Cartulary.Model.Embedding
  alias Cartulary.Model.ModelRoleConfig
  alias Cartulary.Model.Reasoner
  alias Cartulary.Model.Schema.DialecticAnswer

  @cassette "test/fixtures/model/f5-provider-cassette.json"

  setup do
    original_provider = Application.get_env(:cartulary, :model_provider)
    original_roles = Application.fetch_env!(:cartulary, :model_roles)

    on_exit(fn ->
      CassetteProvider.stop()

      if original_provider do
        Application.put_env(:cartulary, :model_provider, original_provider)
      else
        Application.delete_env(:cartulary, :model_provider)
      end

      Application.put_env(:cartulary, :model_roles, original_roles)
    end)

    :ok
  end

  test "four pinned roles and one provider behaviour form the injection seam" do
    assert Model.Config.roles() ==
             [:embedder, :ingest_extractor, :dream_reasoner, :dialectic_agent]

    callbacks = Cartulary.Model.Provider.behaviour_info(:callbacks)

    assert {:structured, 4} in callbacks
    assert {:chat, 3} in callbacks
    assert {:embed, 3} in callbacks
    assert {:rerank, 4} in callbacks

    assert function_exported?(Cartulary.Model.Embedding.Ortex, :dimensions, 1)
    assert function_exported?(Cartulary.Model.Embedding.Ortex, :generate, 2)

    assert {:error, {:model_artifact_missing, :model_path}} =
             Cartulary.Model.Embedding.Ortex.generate(["offline"], dimensions: 384)

    refute ModelRoleConfig
           |> Ash.Changeset.for_create(:create, %{
             role: "ingest_extractor",
             provider: "openrouter",
             model: "test",
             options: %{"api_key" => "must-not-be-persisted"}
           })
           |> Map.fetch!(:valid?)
  end

  test "structured extraction repairs once, resolves subject, and persists full provenance and usage" do
    message = seed_raw!("f5-repair", "avery", "Avery prefers weekly release summaries.")
    account_id = account_id!("f5-repair")

    put_role!(account_id, :ingest_extractor,
      provider: "openrouter",
      model: "openai/gpt-oss-120b",
      model_version: "2026-07",
      prompt_version: "extract-1",
      pipeline_version: "f5-1"
    )

    CassetteProvider.start!(@cassette, "repair_extraction")
    Application.put_env(:cartulary, :model_provider, CassetteProvider)

    assert {:ok, [knowledge]} = Memory.extract_message_for_account(message["id"], account_id)
    assert knowledge["statement"] == "Avery prefers weekly release summaries."
    assert knowledge["subject_peer_id"] == message["peer_id"]
    assert knowledge["confidence"] == 0.93
    assert DateTime.compare(knowledge["revalidate_after"], ~U[2026-10-01 00:00:00Z]) == :eq
    assert knowledge["extracting_provider"] == "openrouter"
    assert knowledge["extracting_model"] == "openai/gpt-oss-120b"
    assert knowledge["extracting_model_version"] == "2026-07"
    assert knowledge["prompt_version"] == "extract-1"
    assert knowledge["pipeline_version"] == "f5-1"

    assert %{
             rows: [
               [
                 2,
                 %Decimal{coef: 115},
                 %Decimal{coef: 44},
                 "openrouter",
                 "2026-07",
                 "extract-1",
                 "f5-1"
               ]
             ]
           } =
             Ecto.Adapters.SQL.query!(
               Repo,
               """
               SELECT count(*),
                      sum(input_tokens),
                      sum(output_tokens),
                      min(provider),
                      min(model_version),
                      min(prompt_version),
                      min(pipeline_version)
               FROM usage_events
               WHERE account_id = $1 AND model_role = 'ingest_extractor'
               """,
               [Ecto.UUID.dump!(account_id)]
             )

    assert %{rows: [["openrouter", "openai/gpt-oss-120b", "2026-07", "extract-1", "f5-1"]]} =
             Ecto.Adapters.SQL.query!(
               Repo,
               """
               SELECT extracting_provider,
                      extracting_model,
                      extracting_model_version,
                      prompt_version,
                      pipeline_version
               FROM provenances
               WHERE knowledge_item_id = $1
               """,
               [Ecto.UUID.dump!(knowledge["id"])]
             )
  end

  test "one cassette provider injects reasoner, dialectic, embedding, and rerank capabilities" do
    _message = seed_raw!("f5-capabilities", "avery", "Avery prefers weekly summaries.")
    account_id = account_id!("f5-capabilities")

    put_role!(account_id, :embedder,
      provider: "ortex",
      model: "test-embedder",
      model_version: "vector-space-3",
      prompt_version: "none",
      pipeline_version: "f5-1",
      embedding_dimensions: 3
    )

    CassetteProvider.start!(@cassette, "capabilities")
    Application.put_env(:cartulary, :model_provider, CassetteProvider)

    DataLayer.with_account_id(
      account_id,
      [role: :system, pipeline?: true],
      fn account, actor ->
        context = %{account_id: account.id, actor: actor}

        assert {:ok, %{items: [], relations: []}, reason_provenance} =
                 Reasoner.reason(%{delta: [], working_set: []}, context)

        assert reason_provenance.pipeline_version == "f5-1"

        assert {:ok, answer, _answer_provenance} =
                 Model.generate_structured(
                   :dialectic_agent,
                   [%{role: "user", content: "What does Avery prefer?"}],
                   DialecticAnswer,
                   context,
                   task: :dialectic
                 )

        assert answer.answer == "Avery prefers weekly summaries."

        assert {:ok, embedding} = Model.embed(["first", "second"], context)
        assert embedding.dimensions == 3
        assert embedding.version == "vector-space-3"
        assert embedding.vectors == [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0]]

        assert {:ok, ranked, _rerank_provenance} =
                 Model.rerank("query", ["first", "second"], context)

        assert [%{"index" => 1}, %{"index" => 0}] = ranked
      end
    )

    assert scalar!(
             "SELECT count(*) FROM usage_events WHERE account_id = $1",
             [Ecto.UUID.dump!(account_id)]
           ) == 4
  end

  test "embedder identity mismatch returns a versioned re-embed plan before vector reuse" do
    current = %{
      provider: "ortex",
      model: "BAAI/bge-small-en-v1.5",
      version: "onnx-2",
      dimensions: 384
    }

    stored = %{current | version: "onnx-1"}

    assert {:error, {:reembed_required, plan}} =
             Embedding.ensure_compatible(stored, current)

    assert plan.pipeline_version == "f5-1"
    assert plan.from.version == "onnx-1"
    assert plan.to.version == "onnx-2"
    refute plan.reuse_existing_vectors
  end

  test "provider outage leaves raw ingest durable and the extraction job retryable" do
    message = seed_raw!("f5-outage", "avery", "Avery prefers weekly summaries.")
    account_id = account_id!("f5-outage")

    put_role!(account_id, :ingest_extractor,
      provider: "openrouter",
      model: "unavailable-model",
      model_version: "1",
      prompt_version: "extract-1",
      pipeline_version: "f5-1"
    )

    CassetteProvider.start!(@cassette, "provider_outage")
    Application.put_env(:cartulary, :model_provider, CassetteProvider)

    assert %{success: 0, failure: 1} = Oban.drain_queue(queue: :ingest)

    assert %{rows: [[1, nil, "pending", 0, queued_jobs]]} =
             Ecto.Adapters.SQL.query!(
               Repo,
               """
               SELECT count(*),
                      message.extraction_completed_at,
                      run.status,
                      run.attempt_count,
                      (SELECT count(*)
                       FROM oban_jobs AS job
                       WHERE job.args->'primary_key'->>'id' = run.id::text
                         AND job.state NOT IN ('completed', 'discarded', 'cancelled'))
               FROM messages AS message
               JOIN pipeline_runs AS run ON run.target_id = message.id
               WHERE message.id = $1 AND run.kind = 'extraction'
               GROUP BY message.extraction_completed_at, run.id, run.status, run.attempt_count
               """,
               [Ecto.UUID.dump!(message["id"])]
             )

    assert queued_jobs >= 1

    assert %{rows: [[1, "error", "openrouter", "unavailable-model"]]} =
             Ecto.Adapters.SQL.query!(
               Repo,
               """
               SELECT count(*), min(status), min(provider), min(model_name)
               FROM usage_events
               WHERE account_id = $1 AND model_role = 'ingest_extractor'
               """,
               [Ecto.UUID.dump!(account_id)]
             )
  end

  defp seed_raw!(account_key, peer_key, content) do
    assert {:ok, message} =
             Memory.ingest_message(%{
               "account_key" => account_key,
               "session_id" => "#{account_key}-session",
               "scope_path" => "/f5/#{account_key}",
               "peer_key" => peer_key,
               "role" => "user",
               "content" => content,
               "sync_extract" => false
             })

    message
  end

  defp put_role!(account_id, role, attrs) do
    DataLayer.with_account_id(
      account_id,
      [role: :system, pipeline?: true],
      fn _account, actor ->
        ModelRoleConfig
        |> Ash.Changeset.new()
        |> Ash.Changeset.set_tenant(account_id)
        |> Ash.Changeset.for_create(
          :create,
          attrs
          |> Map.new()
          |> Map.put(:role, Atom.to_string(role))
          |> Map.put(:version, 1)
          |> Map.put(:active, true)
        )
        |> Ash.create!(actor: actor)
      end
    )
  end

  defp account_id!(account_key) do
    %{rows: [[id]]} =
      Ecto.Adapters.SQL.query!(Repo, "SELECT id::text FROM accounts WHERE key = $1", [account_key])

    id
  end

  defp scalar!(sql, params) do
    %{rows: [[value]]} = Ecto.Adapters.SQL.query!(Repo, sql, params)
    value
  end
end
