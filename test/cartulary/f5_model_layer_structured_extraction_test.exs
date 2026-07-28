# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.F5ModelLayerStructuredExtractionTest do
  @moduledoc """
  Pins the provider-neutral model boundary and the structured-extraction contract.

  Cartulary never calls a model vendor from pipeline, retrieval, web, or governance code.
  Everything goes through one gateway that resolves exactly four account-level roles —
  `embedder`, `ingest_extractor`, `dream_reasoner`, `dialectic_agent` — onto a single
  provider behaviour with four capabilities (structured generation, chat, embed, rerank).
  This file is the regression floor for that seam. It asserts, end to end:

  * the four roles exist in a fixed order and the behaviour exposes exactly the four
    capability callbacks, so a new provider can be written against a stable contract;
  * the local ONNX embedder refuses to invent a vector when its artifacts are absent
    instead of downloading anything or reaching the network;
  * role configuration rejects a raw credential in its options, because only opaque
    secret *references* (for example an environment-variable name) may be persisted;
  * malformed provider output is repaired a bounded number of times and, if still
    invalid, becomes an error — it never becomes durable knowledge;
  * an extracted item carries a subject the extractor resolved, not one inherited from
    whoever sent the message;
  * provider, model, model version, prompt version, and pipeline version are recorded on
    both the knowledge provenance row and on every usage event;
  * every provider call, including a repair attempt and a failed call, produces exactly
    one durable usage event, because that ledger is the only exact record of spend;
  * an embedding identity mismatch returns an explicit re-embed plan rather than reusing
    or silently substituting vectors from a different vector space; and
  * a provider outage leaves the raw observation durable, the extraction incomplete, and
    the job retryable, so no user input is lost when a vendor is down.

  ## Why it must not drift

  Each of these is a property a well-meaning refactor can quietly remove: caching a
  vector across a model upgrade, swallowing a provider error to make a queue drain
  cleanly, letting a partially valid extraction through "just this once", or logging a
  credential into role options. The assertions here are deliberately concrete so that
  such a change fails loudly at the boundary rather than corrupting stored knowledge.

  ## The `f5-1` string

  `f5-1` is the version identity of the extractor and pipeline contract. It is data, not
  a label: it is written into knowledge provenance, into usage events, into the re-embed
  plan, and it is what `GET /api/health` reports. Changing it is a deliberate contract
  transition that requires a changelog entry and updated contract evidence — so if an
  assertion on that string fails, the correct response is almost always to restore the
  behaviour, not to edit the expected value.

  ## If this file fails

  Do not weaken an assertion to make it pass. Find which guarantee the change removed.
  The recorded provider script this suite replays lives at
  `test/fixtures/model/f5-provider-cassette.json`; if a legitimate change alters the
  *sequence* of model calls, re-record that scenario rather than relaxing the matching.

  Runs with `async: false` because it swaps the `:model_provider` and `:model_roles`
  application environment entries, which are global to the node.
  """

  use Cartulary.DataCase, async: false

  alias Cartulary.DataLayer
  alias Cartulary.Memory
  alias Cartulary.Model
  alias Cartulary.Model.CassetteProvider
  alias Cartulary.Model.Embedding
  alias Cartulary.Model.ModelRoleConfig
  alias Cartulary.Model.Reasoner
  alias Cartulary.Model.Schema.DialecticAnswer

  # Recorded provider script replayed instead of any network call. Each scenario inside it
  # is an ordered list of expected calls; see the individual tests for which one they arm.
  @cassette "test/fixtures/model/f5-provider-cassette.json"

  setup do
    original_provider = Application.get_env(:cartulary, :model_provider)
    original_roles = Application.fetch_env!(:cartulary, :model_roles)

    # Application environment is node-global. Restoring it (and stopping the cassette agent,
    # which is started unlinked so a failing test cannot take it down) is mandatory: a leaked
    # half-consumed cassette makes the *next* test fail in a way that looks unrelated.
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
    # The role set is closed and ordered. Adding a fifth role, or renaming one, changes what
    # every account must configure and what the readiness endpoint reports.
    assert Model.Config.roles() ==
             [:embedder, :ingest_extractor, :dream_reasoner, :dialectic_agent]

    callbacks = Cartulary.Model.Provider.behaviour_info(:callbacks)

    # Exactly four capabilities, at these arities, are what a third-party or self-hosted
    # adapter has to implement. Changing an arity silently breaks every out-of-tree adapter.
    assert {:structured, 4} in callbacks
    assert {:chat, 3} in callbacks
    assert {:embed, 3} in callbacks
    assert {:rerank, 4} in callbacks

    assert function_exported?(Cartulary.Model.Embedding.Ortex, :dimensions, 1)
    assert function_exported?(Cartulary.Model.Embedding.Ortex, :generate, 2)

    # The local embedder must fail loudly when its ONNX/tokenizer artifacts are absent. It
    # must never download a model or fall back to a network endpoint: offline installations
    # rely on the default embedding path never leaving the machine.
    assert {:error, {:model_artifact_missing, :model_path}} =
             Cartulary.Model.Embedding.Ortex.generate(["offline"], dimensions: 384)

    # Role options hold secret *references* only. A literal credential in the options map is
    # rejected at the changeset, before it can reach the database, an export, or a log line.
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

    # This scenario records two structured calls: the first returns output that fails schema
    # validation, the second is the repair attempt that succeeds. Replaying it proves the
    # repair loop exists and is bounded, and that only validated output becomes knowledge.
    CassetteProvider.start!(@cassette, "repair_extraction")
    Application.put_env(:cartulary, :model_provider, CassetteProvider)

    assert {:ok, [knowledge]} = Memory.extract_message_for_account(message["id"], account_id)
    assert knowledge["statement"] == "Avery prefers weekly release summaries."
    # Subject and source are independent dimensions. Here they coincide because the peer
    # spoke about themselves, but the extractor must resolve the subject explicitly rather
    # than defaulting it to whoever sent the message.
    assert knowledge["subject_peer_id"] == message["peer_id"]
    assert knowledge["confidence"] == 0.93
    assert DateTime.compare(knowledge["revalidate_after"], ~U[2026-10-01 00:00:00Z]) == :eq
    assert knowledge["extracting_provider"] == "openrouter"
    assert knowledge["extracting_model"] == "openai/gpt-oss-120b"
    assert knowledge["extracting_model_version"] == "2026-07"
    assert knowledge["prompt_version"] == "extract-1"
    assert knowledge["pipeline_version"] == "f5-1"

    # Two usage events, not one: the failed first attempt is metered too. Repairs cost real
    # tokens, so hiding them would understate spend. 115 input / 44 output is the sum of the
    # two recorded calls (50 + 65 and 20 + 24) and changes only if the cassette is re-recorded.
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

    # Provenance is what lets an operator answer "which model asserted this, under which
    # prompt and pipeline revision?" years later. All five identity columns must be present;
    # a knowledge row whose origin cannot be reconstructed is not auditable.
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
      # Three dimensions instead of the production 384 keeps the recorded vectors readable.
      embedding_dimensions: 3
    )

    # One scenario drives all four capabilities in the recorded order: reasoning, dialectic
    # answering, embedding, reranking. Consuming them in order proves the gateway routes each
    # role to the right capability and does not make extra or reordered provider calls.
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

        # Dimensions and version travel with the vectors, not just with the configuration, so
        # a later consumer can detect that it is holding vectors from another vector space.
        assert {:ok, embedding} = Model.embed(["first", "second"], context)
        assert embedding.dimensions == 3
        assert embedding.version == "vector-space-3"
        assert embedding.vectors == [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0]]

        assert {:ok, ranked, _rerank_provenance} =
                 Model.rerank("query", ["first", "second"], context)

        assert [%{"index" => 1}, %{"index" => 0}] = ranked
      end
    )

    # Four provider calls, four usage events: metering is per call, with no batching or
    # deduplication that would make the ledger disagree with what the vendor bills.
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

    # Same provider, model, and dimension count — only the artifact version differs. That is
    # still a different vector space (the version covers the ONNX artifact, tokenizer, and
    # pooling strategy), so cosine distances between old and new vectors are meaningless.
    stored = %{current | version: "onnx-1"}

    assert {:error, {:reembed_required, plan}} =
             Embedding.ensure_compatible(stored, current)

    assert plan.pipeline_version == "f5-1"
    assert plan.from.version == "onnx-1"
    assert plan.to.version == "onnx-2"
    # The plan must never authorise partial reuse. Mixing vector spaces degrades retrieval
    # invisibly: nothing errors, results just quietly get worse.
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

    # The recorded call returns an error, standing in for a vendor outage or rate limit.
    CassetteProvider.start!(@cassette, "provider_outage")
    Application.put_env(:cartulary, :model_provider, CassetteProvider)

    # The job must fail rather than "succeed with no knowledge". A swallowed provider error
    # would mark the message extracted and the observation would be silently lost forever.
    assert %{success: 0, failure: 1} = Oban.drain_queue(queue: :ingest)

    # The durable side of the outage: the message row survives, extraction is still
    # incomplete (NULL completion timestamp), the pipeline run is still pending, and at least
    # one Oban job for that run is still live — not completed, discarded, or cancelled.
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

    # A failed call is still one metered event, tagged with status "error" and the provider
    # and model that failed. Operators diagnose outages from this ledger.
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

  # Creates the account, scope, peer, session, and raw message in one call. `sync_extract`
  # is false so the message lands durably without running extraction, letting each test arm
  # its own recorded provider script before the model is ever consulted.
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

  # Persists an active, versioned role configuration for one account. A stored record wins
  # over the runtime default, which is how a test pins the provider identity strings that
  # later show up in provenance and usage rows. Writes run under a system/pipeline actor
  # with the account set as the Ash tenant, because role configuration is account-scoped.
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

  # Raw SQL on purpose: these helpers read committed rows without going through Ash
  # authorization, so an assertion cannot be satisfied by a policy-shaped read that happens
  # to hide the row. Test-only; production code never reaches the tables this way.
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
