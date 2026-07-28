# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.F1AshDomainBackboneTest do
  use Cartulary.DataCase, async: false

  alias Cartulary.Actor
  alias Cartulary.DataLayer
  alias Cartulary.Governance.AuditEvent
  alias Cartulary.Governance.PolicyConfig
  alias Cartulary.Knowledge.KnowledgeItem
  alias Cartulary.Knowledge.LifecycleEvent
  alias Cartulary.Memory
  alias Cartulary.Observations.Message
  alias Cartulary.Repo
  alias Cartulary.Topology.Scope

  @domains [
    Cartulary.Accounts,
    Cartulary.Topology,
    Cartulary.Observations,
    Cartulary.Documents,
    Cartulary.Knowledge,
    Cartulary.Governance,
    Cartulary.Model,
    Cartulary.Retrieval,
    Cartulary.Skills,
    Cartulary.Operations
  ]

  @resources [
    Cartulary.Accounts.Account,
    Cartulary.Accounts.ApiKey,
    Cartulary.Accounts.ExternalIdentity,
    Cartulary.Accounts.Peer,
    Cartulary.Documents.ConnectorConfig,
    Cartulary.Documents.DocumentChunk,
    Cartulary.Governance.AuditEvent,
    Cartulary.Governance.Consent,
    Cartulary.Governance.ErasureRequest,
    Cartulary.Governance.GateDecision,
    Cartulary.Governance.GateRule,
    Cartulary.Governance.McpTools,
    Cartulary.Governance.PeerAskPreference,
    Cartulary.Governance.PeerQuery,
    Cartulary.Governance.PeerQueryDelivery,
    Cartulary.Governance.PolicyConfig,
    Cartulary.Governance.ValidationItem,
    Cartulary.Knowledge.Attribution,
    Cartulary.Knowledge.Entity,
    Cartulary.Knowledge.EntityMention,
    Cartulary.Knowledge.KnowledgeItem,
    Cartulary.Knowledge.KnowledgeRelation,
    Cartulary.Knowledge.LifecycleEvent,
    Cartulary.Knowledge.Projection,
    Cartulary.Knowledge.Provenance,
    Cartulary.Model.ModelRoleConfig,
    Cartulary.Observations.Document,
    Cartulary.Observations.DocumentVersion,
    Cartulary.Observations.Message,
    Cartulary.Observations.Session,
    Cartulary.Observations.SessionParticipant,
    Cartulary.Observations.SessionScope,
    Cartulary.Operations.PipelineRun,
    Cartulary.Operations.UsageEvent,
    Cartulary.Retrieval.RetrievalProfile,
    Cartulary.Skills.SkillRequirementCard,
    Cartulary.Topology.RoleGrant,
    Cartulary.Topology.Scope,
    Cartulary.Topology.ScopeRelation
  ]

  @rls_tables ~w(
    accounts api_keys attributions audit_events connector_configs document_chunks document_versions
    documents entities entity_mentions erasure_requests external_identities gate_decisions
    governance_gate_rules knowledge_consents knowledge_items knowledge_lifecycle_events
    knowledge_relations messages model_role_configs peer_ask_preferences peer_queries
    peer_query_deliveries peers pipeline_runs policy_configs projections provenances
    retrieval_profiles role_grants scope_relations scopes session_participants session_scopes
    sessions skill_requirement_cards usage_events validation_items
  )

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

  test "the F1 resource inventory is registered across the modular Ash domains" do
    resources =
      @domains
      |> Enum.flat_map(&Ash.Domain.Info.resources/1)
      |> Enum.sort()

    assert resources == Enum.sort(@resources)
    assert Application.fetch_env!(:cartulary, :ash_domains) == @domains
  end

  test "Ash actions enforce the Account wall and governance separation" do
    seed!("f1-action-a", "/f1/action/a")
    seed!("f1-action-b", "/f1/action/b")

    {account_a, actor_a} =
      DataLayer.with_account_key("f1-action-a", fn account, actor -> {account, actor} end)

    {account_b, _actor_b} =
      DataLayer.with_account_key("f1-action-b", fn account, actor -> {account, actor} end)

    assert [] =
             Scope
             |> Ash.Query.set_tenant(account_b.id)
             |> Ash.read!(actor: actor_a)

    visible_scope_id = scope_id!("f1-action-a", "/f1/action/a")
    scope_limited_actor = Actor.for_account(account_a, scope_ids: [visible_scope_id])

    assert [%Scope{path: "/f1/action/a"}] =
             Scope
             |> Ash.Query.set_tenant(account_a.id)
             |> Ash.read!(actor: scope_limited_actor)

    assert {:error, _forbidden} =
             KnowledgeItem
             |> Ash.Changeset.for_create(:create_from_pipeline, %{
               scope_id: visible_scope_id,
               statement: "A member attempted to bypass the knowledge pipeline."
             })
             |> Ash.Changeset.set_tenant(account_a.id)
             |> Ash.create(actor: actor_a)

    assert {:error, _forbidden} =
             PolicyConfig
             |> Ash.Changeset.for_create(:create, %{
               key: "gate-b",
               value: %{threshold: 0.9},
               version: 1
             })
             |> Ash.Changeset.set_tenant(account_a.id)
             |> Ash.create(actor: actor_a)

    admin = Actor.for_account(account_a, role: :account_admin)

    assert {:ok, %PolicyConfig{key: "gate-b"}} =
             PolicyConfig
             |> Ash.Changeset.for_create(:create, %{
               key: "gate-b",
               value: %{threshold: 0.9},
               version: 1
             })
             |> Ash.Changeset.set_tenant(account_a.id)
             |> Ash.create(actor: admin)
  end

  test "content is create-only except for the F4 erasure action and ledgers remain append-only" do
    assert action_types(Message) == [:create, :destroy, :read, :update]
    assert Ash.Resource.Info.action(Message, :erase).type == :destroy
    assert action_types(LifecycleEvent) == [:create, :read]
    assert action_types(AuditEvent) == [:create, :read]

    refute :statement in action_accept(KnowledgeItem, :merge_from_pipeline)
    refute :statement in action_accept(KnowledgeItem, :transition)
    assert :statement in action_accept(KnowledgeItem, :create_from_pipeline)
  end

  test "Postgres RLS filters reads and rejects cross-Account writes for a non-owner role" do
    seed!("f1-rls-a", "/f1/rls/a")
    seed!("f1-rls-b", "/f1/rls/b")

    account_a_id = account_id!("f1-rls-a")
    account_b_id = account_id!("f1-rls-b")
    role = "cartulary_rls_#{System.unique_integer([:positive])}"

    assert %{rows: policy_rows} =
             Ecto.Adapters.SQL.query!(
               Repo,
               """
               SELECT class.relname
               FROM pg_class AS class
               JOIN pg_namespace AS namespace ON namespace.oid = class.relnamespace
               JOIN pg_policy AS policy ON policy.polrelid = class.oid
               WHERE namespace.nspname = 'public'
                 AND class.relname = ANY($1)
                 AND class.relrowsecurity
                 AND class.relforcerowsecurity
                 AND policy.polname = 'cartulary_account_wall'
               ORDER BY class.relname
               """,
               [@rls_tables]
             )

    assert Enum.map(policy_rows, &hd/1) == Enum.sort(@rls_tables)

    sql!("CREATE ROLE #{role} NOLOGIN")
    sql!("GRANT USAGE ON SCHEMA public TO #{role}")
    sql!("GRANT SELECT, INSERT ON accounts, scopes TO #{role}")
    sql!("SET LOCAL ROLE #{role}")

    Ecto.Adapters.SQL.query!(
      Repo,
      "SELECT set_config('cartulary.account_id', $1, true)",
      [account_a_id]
    )

    assert %{rows: [[^account_a_id, "/f1/rls/a"]]} =
             Ecto.Adapters.SQL.query!(
               Repo,
               """
               SELECT account_id::text, path
               FROM scopes
               WHERE path IN ('/f1/rls/a', '/f1/rls/b')
               ORDER BY path
               """,
               []
             )

    assert_raise Postgrex.Error, fn ->
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        INSERT INTO scopes
          (id, account_id, key, name, path, state, inserted_at, updated_at)
        VALUES
          (gen_random_uuid(), $1::uuid, 'blocked', 'blocked', '/f1/rls/blocked',
           'active', NOW(), NOW())
        """,
        [Ecto.UUID.dump!(account_b_id)]
      )
    end
  end

  defp seed!(account_key, scope_path) do
    assert {:ok, _message} =
             Memory.ingest_message(%{
               "account_key" => account_key,
               "session_id" => "#{account_key}-session",
               "scope_path" => scope_path,
               "peer_key" => "#{account_key}-peer",
               "content" => "F1 keeps every Account behind Ash actions and PostgreSQL RLS."
             })
  end

  defp action_types(resource) do
    resource
    |> Ash.Resource.Info.actions()
    |> Enum.map(& &1.type)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp action_accept(resource, action_name) do
    resource
    |> Ash.Resource.Info.action(action_name)
    |> Map.fetch!(:accept)
  end

  defp account_id!(key) do
    %{rows: [[id]]} =
      Ecto.Adapters.SQL.query!(Repo, "SELECT id::text FROM accounts WHERE key = $1", [key])

    id
  end

  defp scope_id!(account_key, path) do
    %{rows: [[id]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT scope.id::text
        FROM scopes AS scope
        JOIN accounts AS account ON account.id = scope.account_id
        WHERE account.key = $1 AND scope.path = $2
        """,
        [account_key, path]
      )

    id
  end

  defp sql!(statement), do: Ecto.Adapters.SQL.query!(Repo, statement, [])
end
