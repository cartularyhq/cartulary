# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule VanishingSubjectProvider do
  @moduledoc """
  Test model provider that makes the write following its answer fail, on purpose.

  It answers one structured extraction with a schema-valid candidate about the peer named
  `avery-key`, and, as a side effect of answering, renames that peer. The extractor built its
  prompt and its list of nameable peers before the call, so the candidate still validates;
  subject resolution then finds no such peer and raises rather than re-attributing the
  statement to whoever spoke.

  That is the only way to observe, from inside the SQL sandbox, whether the model call shares
  a transaction with the write that follows it. Every test already runs inside one sandbox
  transaction, so `Repo.in_transaction?/0` is useless here; what is observable is whether the
  usage row this call produces survives the failure. It survives only if the two were written
  in separate transactions.

  The rename is raw SQL because it has to happen mid-call, from the provider, with no actor
  and no Ash action available. It relies on the Account's row-level-security setting still
  being installed on the sandbox connection, which it is: the extraction's read phase
  installed it just before this call.

  Only `structured/4` is meaningful. The other three capabilities exist because the behaviour
  requires them and return an error, so a test that reaches them fails loudly instead of
  receiving a fabricated answer.
  """

  @behaviour Cartulary.Model.Provider

  alias Cartulary.Model.Provider.Result
  alias Cartulary.Repo

  # The peer key `ingest_attrs/3` derives for the Account key `f2-metered-failure`, and the
  # name it is moved to. Both are literals rather than parameters because the provider
  # behaviour gives a provider no way to receive test-specific configuration.
  @subject_key "f2-metered-failure-peer"
  @moved_key "f2-metered-failure-peer-moved"

  @doc """
  Answers one extraction and renames its subject peer, so the write that follows raises.

  Returns a `Result` whose value is a single schema-valid candidate, with token counts set so
  the usage row this call produces is recognisable.
  """
  @impl true
  def structured(_config, _messages, _schema, _opts) do
    Ecto.Adapters.SQL.query!(Repo, "UPDATE peers SET key = $1 WHERE key = $2", [
      @moved_key,
      @subject_key
    ])

    {:ok,
     %Result{
       value: %{
         "items" => [
           %{
             "statement" => "Avery prefers concise weekly release summaries.",
             "kind" => "preference",
             "subject_type" => "peer",
             "subject_ref" => @subject_key,
             "confidence" => 0.9,
             "sensitivity" => "internal",
             "target_level" => "peer",
             "update_operation" => "add",
             "hearsay" => false
           }
         ]
       },
       usage: %{input_tokens: 11, output_tokens: 4},
       metadata: %{}
     }}
  end

  @doc "Unused capability; returns an error so an unexpected call fails the test."
  @impl true
  def chat(_config, _messages, _opts), do: {:error, :not_implemented}

  @doc "Unused capability; returns an error so an unexpected call fails the test."
  @impl true
  def embed(_config, _texts, _opts), do: {:error, :not_implemented}

  @doc "Unused capability; returns an error so an unexpected call fails the test."
  @impl true
  def rerank(_config, _query, _documents, _opts), do: {:error, :not_implemented}
end

defmodule Cartulary.F2TransactionalWritesAuditJobsTest do
  @moduledoc """
  Pins the coupling between a durable write, its audit entry, its processing record, and its
  background job: either all four exist or none of them do.

  The file name and module name are frozen evidence identities and are not renamed. What they
  guard is the property that makes the rest of the system trustworthy — there is no window in
  which an observation is stored but unaudited, audited but unqueued, or queued for work that
  was rolled back. Five things are pinned here.

  **One transaction, four effects.** Accepting a raw observation writes the observation row,
  appends an audit event, creates (or reuses) a durable processing record, and inserts the
  background job in the same database transaction. A failure at any point after the enqueue
  unwinds all of them, so a job can never reference a row that does not exist and a stored row
  can never be left with nobody scheduled to process it.

  **Audit is content-safe.** An audit event records a SHA-256 digest of the content and
  content-free metadata such as a role and a session identifier. Raw text never enters audit
  metadata, job arguments, or telemetry, because those travel to places the content itself is
  not allowed to go.

  **The audit trail is a per-Account hash chain.** Each event stores the hash of the previous
  event for its Account and its own hash over a fixed payload. Recomputing the chain from the
  stored fields must reproduce every hash, which is what turns "we have logs" into "the logs
  have not been altered". The chain head starts empty for a new Account, so the first event
  links to nothing.

  **Work is replay-safe.** Every job lane derives a deterministic idempotency key from its
  inputs. The same inputs must produce the same key, so a retry, a reconciler sweep, and an
  inline run all converge on one unit of work; different inputs or different lanes must
  produce different keys, so unrelated work is never mistaken for a duplicate and silently
  dropped. Re-running extraction merges into the existing knowledge instead of minting a
  second copy or appending a second creation lifecycle event.

  **Extraction is not a precondition for durability.** An observation ingested without an
  inline extraction still commits with its processing record; it stays marked unprocessed so
  the reconciler will come back to it.

  ## If a test in this file fails

  Treat it as a durability or integrity defect rather than a flaky test. Splitting one of the
  four writes out of the transaction, moving the enqueue after commit, copying content into
  audit metadata or job arguments, or changing the fields that feed the event hash will each
  break a specific test here. The last one also invalidates every previously stored chain, so
  it needs a migration plan, not just a new expected value.
  """

  use Cartulary.DataCase, async: false

  alias Cartulary.Clock
  alias Cartulary.DataLayer
  alias Cartulary.Governance.Audit
  alias Cartulary.Governance.AuditEvent
  alias Cartulary.Memory
  alias Cartulary.Observations.Message
  alias Cartulary.Operations.PipelineRun
  alias Cartulary.Pipeline.Idempotency

  # Clears every credential a provider could pick up, so nothing here can reach a network
  # endpoint. The provider-outage test below deliberately writes a broken configuration back.
  # Both values are global to the node, so this module is not async and both are restored
  # afterwards.
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

    # One query with sub-selects, deliberately: it observes the observation row, the audit
    # event, the processing record, and the queued job at a single point in time. Four separate
    # queries could each pass against a half-committed state.
    #
    # The job is matched on the Account tenant and the lane name in its arguments, because the
    # test has no handle on the job id. Job arguments hold ids, a replay key, and a lane name;
    # no content and no secret may be placed there, since anyone who can read the queue table
    # can read them.
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

    # The audit event points at the content by digest. Recomputing the digest from the stored
    # message proves the reference is real without the audit row ever holding the text.
    assert content_hash == Idempotency.content_hash(message["content"])
    assert message_count == 1
    assert run_count == 1
    assert job_count == 1

    # Exactly one reconciler record per Account, not one per ingest. The reconciler re-enqueues
    # observations whose extraction never completed; its idempotency key is per Account, so
    # repeated ingests collapse onto the same record instead of flooding the queue.
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

    # Snapshot of message, audit, processing-record, and job counts taken before the doomed
    # write. The seed ingest above exists so these counts start non-zero and a rollback that
    # wiped everything would also be caught.
    before = account_counts("f2-rollback")
    {session_id, scope_id, peer_id} = observation_ids!("f2-rollback")

    # The private context flag makes the create fail *after* the audit event and the enqueue
    # have already run inside the transaction — the exact window where a non-transactional
    # implementation would leave an orphaned audit entry and a job for a row that never
    # existed. The flag is reachable only from a changeset's private context, never from
    # request input, and the production code path that honours it is here for this test: do
    # not delete it as dead code.
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

    # All four counters unchanged. A single one moving means that write escaped the
    # transaction and the four effects are no longer atomic.
    assert account_counts("f2-rollback") == before
  end

  test "AshOban extraction executes the ingest Reactor and marks durable processing complete" do
    # `sync_extract: false` returns as soon as the observation is durable, leaving the work to
    # the queue, so this test exercises the real background path rather than the inline one.
    assert {:ok, message} =
             Memory.ingest_message(ingest_attrs("f2-drain", "drain-session", sync_extract: false))

    # Runs the queued job in this process. It can see the test's uncommitted rows only because
    # the sandbox connection is shared, which is why this module cannot be async.
    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :ingest)

    # Three facts in one row: the observation is marked processed, knowledge was produced from
    # it, and the durable processing record reached `completed`. The completion marker is what
    # keeps the reconciler from picking the message up again forever.
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

    # The ingest above already extracted inline, so the baseline is taken after that first run.
    before = knowledge_counts(account_id)

    # Two more extractions of the same observation stand in for the ways replay really happens:
    # a retried job, a reconciler sweep, and an inline run racing the queued one. Each returns
    # the knowledge as if it had just produced it — replay is a normal outcome, not an error.
    assert {:ok, [_knowledge]} =
             Memory.extract_message_for_account(message["id"], account_id)

    assert {:ok, [_knowledge]} =
             Memory.extract_message_for_account(message["id"], account_id)

    # Nothing new was written: not a duplicate knowledge item, not a second creation lifecycle
    # event, not a repeated attribution, provenance, or audit entry. Duplicates here would
    # inflate corroboration counts, so a statement could be promoted for having been said once.
    assert knowledge_counts(account_id) == before
  end

  test "provider unavailability cannot prevent raw persistence and transactional enqueue" do
    # Points the legacy `:models` credential and base URL at a port nothing listens on, so any
    # provider call made under this configuration would fail on connect rather than hang. The
    # ingest below passes `sync_extract: false`, so no model call is attempted here; what the
    # assertions prove is that the durable observation and its processing record do not depend
    # on extraction having produced anything.
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

    # `sync_extract: false` returns the observation with no "knowledge" key at all, so the
    # caller is never handed a fabricated or fallback result while extraction is still pending.
    refute Map.has_key?(message, "knowledge")

    # The observation is stored and still marked unprocessed, so the reconciler will pick it up.
    assert scalar!(
             """
             SELECT count(*)
             FROM messages
             WHERE id = $1
               AND extraction_completed_at IS NULL
             """,
             [Ecto.UUID.dump!(message["id"])]
           ) == 1

    # And the durable processing record survives the provider failure, so the work is retryable
    # rather than lost.
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

    # Reading audit needs an admin, curator, or system role; ordinary members and readers have
    # no route to it. Sorting by insertion order with the id as a tiebreak reproduces the order
    # the chain was built in, which is the only order in which the links verify.
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

    # A floor rather than an exact count, so adding a new audited action elsewhere does not
    # break this test. The named actions are the ones a single ingest must always leave behind:
    # the knowledge moved state, and both governance gates recorded what they decided.
    assert length(events) >= 4
    assert Enum.any?(events, &(&1.action == "knowledge.transitioned"))
    assert Enum.any?(events, &(&1.action == "gate_a.defer"))
    assert Enum.any?(events, &(&1.action == "gate_b.provisional"))

    # Walk the chain, carrying the previous event's hash. The accumulator starts at nil because
    # the first event of an Account links to nothing.
    events
    |> Enum.reduce(nil, fn event, previous_hash ->
      # Each link points at its predecessor, and the hash is a full 64-character hex SHA-256.
      # A gap or a re-pointed link means an event was removed or inserted after the fact.
      assert event.previous_hash == previous_hash
      assert event.event_hash =~ ~r/\A[0-9a-f]{64}\z/

      # Content safety: the observed text must not appear anywhere in the event metadata.
      # Inspecting the whole term catches it however deeply it was nested.
      refute inspect(event.metadata) =~ content

      # Recompute the hash from the stored fields. This exact field set, in this shape, defines
      # the chain: adding, removing, or re-typing any of them changes every future hash and
      # invalidates every chain already written, so it is a migration, not a tweak.
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
    # The complete set of background lanes. Listing them exactly means a new lane cannot be
    # added without a reviewer noticing that it also needs an idempotency key family, a
    # reconciler story, and content-free job arguments.
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

    # Each lane's orchestration module must exist and compile. A trigger whose workflow module
    # is missing would only fail when a real job ran, in production, at retry time.
    assert Code.ensure_loaded?(Cartulary.Pipeline.Workflows.IngestExtraction)
    assert Code.ensure_loaded?(Cartulary.Pipeline.Workflows.DreamTimeReasoning)
    assert Code.ensure_loaded?(Cartulary.Pipeline.Workflows.ValidationContinuation)
    assert Code.ensure_loaded?(Cartulary.Pipeline.Workflows.AnswerCorrelationContinuation)

    # Idempotency keys need two opposite properties, and both are checked here.
    #
    # Stable: identical inputs give an identical key, so a retry or a reconciler sweep lands on
    # the work that already exists instead of starting a second copy.
    message_id = Ecto.UUID.generate()
    message_key = Idempotency.message_extraction(message_id, "content-hash")

    assert message_key ==
             Idempotency.message_extraction(message_id, "content-hash")

    # Distinct: different lanes and different inputs must never collide, or one piece of work
    # would be discarded as a duplicate of an unrelated one and never run at all. The pairs
    # below are the collisions that could plausibly happen if a key were built from too few
    # components — two lanes sharing a scope and watermark, one import with two manifests.
    assert message_key != Idempotency.document_extraction(Ecto.UUID.generate(), "content-hash")

    scope_id = Ecto.UUID.generate()
    assert Idempotency.dream_time(scope_id, 42) == Idempotency.dream_time(scope_id, 42)

    assert Idempotency.projection_refresh(scope_id, 42) !=
             Idempotency.entity_resolution(scope_id, 42)

    assert Idempotency.import_rebuild("import-1", "manifest-a") !=
             Idempotency.import_rebuild("import-1", "manifest-b")

    # The audit categories are a closed vocabulary. Every audited action must fall into one of
    # them, so operators can filter and retain the trail without knowing each action name.
    assert Enum.sort(Audit.categories()) ==
             Enum.sort(
               ~w(attribution configuration deletion gate governance lifecycle observation)
             )
  end

  test "a billed model call stays metered when the write that follows it fails" do
    assert {:ok, message} =
             Memory.ingest_message(
               ingest_attrs("f2-metered-failure", "metered-failure-session", sync_extract: false)
             )

    account_id = account_id!("f2-metered-failure")

    original_provider = Application.get_env(:cartulary, :model_provider)

    on_exit(fn ->
      if original_provider do
        Application.put_env(:cartulary, :model_provider, original_provider)
      else
        Application.delete_env(:cartulary, :model_provider)
      end
    end)

    Application.put_env(:cartulary, :model_provider, VanishingSubjectProvider)

    # The provider renames the subject peer as a side effect of answering, so the candidate it
    # returns names a peer key that existed when the prompt was built and no longer exists
    # when the write runs. Subject resolution refuses to re-attribute the statement to the
    # speaker and raises instead, which is the failure this test needs.
    assert_raise ArgumentError, ~r/unknown peer/, fn ->
      Memory.extract_message_for_account(message["id"], account_id)
    end

    # The call was made and billed. Rolling its ledger row back with the failed write would
    # understate real spend and hide a vendor charge the operator still owes, so the usage
    # write must not share a transaction with the knowledge write.
    assert scalar!(
             """
             SELECT count(*) FROM usage_events
             WHERE account_id = $1 AND model_role = 'ingest_extractor'
             """,
             [Ecto.UUID.dump!(account_id)]
           ) == 1

    # The failure still left nothing half-written and nothing claimed as processed, so the
    # durable job retries the whole extraction.
    assert knowledge_counts(account_id) == {0, 0, 0, 0, 1}

    assert scalar!(
             "SELECT count(*) FROM messages WHERE id = $1 AND extraction_completed_at IS NULL",
             [Ecto.UUID.dump!(message["id"])]
           ) == 1
  end

  # Builds one ingest payload. Every test uses its own Account key so the count assertions are
  # not disturbed by rows another test in this file created. Overrides are given as a keyword
  # list purely for readability at the call sites and are converted to the string keys the
  # ingest entry point expects.
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

  # Resolves the Account identifier as text, because the counting queries below compare it
  # against the job arguments, where it is stored as a JSON string rather than a UUID.
  defp account_id!(account_key) do
    %{rows: [[id]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT id::text FROM accounts WHERE key = $1",
        [account_key]
      )

    id
  end

  # Returns the session, scope, and peer the seed ingest created, so the rollback test can
  # build a second observation against real parents. It reads them from the database rather
  # than creating fresh ones, because creating them would itself add rows and move the
  # before/after counts the test compares.
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

  # The four counts that must move together: observations, audit events, processing records,
  # and queued jobs. Read in one statement so the tuple is a consistent snapshot. Jobs are
  # matched on the Account carried in their arguments, since the queue table is not itself an
  # Account-scoped resource.
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

  # Everything a replayed extraction could wrongly duplicate: the knowledge item itself, its
  # lifecycle history, who said it, where it came from, and the audit trail. All five are
  # compared as one tuple so a single leaked duplicate fails the test.
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

  # Runs a parameterized query expected to return exactly one column of one row, and fails the
  # match if it returns anything else.
  defp scalar!(sql, params) do
    %{rows: [[value]]} = Ecto.Adapters.SQL.query!(Repo, sql, params)
    value
  end
end
