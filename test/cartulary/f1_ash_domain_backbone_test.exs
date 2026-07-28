# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.F1AshDomainBackboneTest do
  @moduledoc """
  Pins the durable-data boundary: every persistent row is owned by an Ash resource, reachable
  only through an Ash action, and walled off per Account by PostgreSQL row-level security.

  The file name and module name are frozen evidence identities and are not renamed; what they
  guard is the backbone of the data model. Four properties are pinned.

  **The resource inventory is a closed set.** The domain and resource lists below are a
  deliberate tripwire, not a convenience. Adding a durable resource without adding it here
  fails this suite, which forces the author to notice that a new table needs a reviewed
  migration, a snapshot, a tenancy attribute, and a row-level-security policy. The same
  assertion checks that the configured domain list matches, because a domain module that
  exists but is not configured produces no code generation and no migrations.

  **Authorization is derived from identity, never from request input.** Pointing a query at
  another Account's tenant does not grant access; it returns nothing. An actor restricted to a
  subset of scopes sees only those scopes. Knowledge cannot be minted by an ordinary actor —
  only the pipeline may create it — and configuration changes need an administrator.

  **Content is create-only and ledgers are append-only.** Observation content may be created
  and erased but never rewritten, knowledge statements are immutable once minted, and
  lifecycle and audit rows expose only create and read actions so history cannot be edited
  away.

  **Row-level security is the last line of defence.** Every table carrying an Account
  identifier has row-level security enabled *and* forced, with one named policy that compares
  the row's Account against a transaction-local PostgreSQL setting. Forced mode matters
  because a plain enabled policy is skipped for the table owner, which is exactly the role a
  release usually connects as. The policy filters reads and, through its check clause, also
  refuses writes aimed at another Account.

  ## If a test in this file fails

  A mismatch in the inventory lists means a resource or domain was added or removed: confirm
  the migration, the resource snapshot, the tenancy attribute, and the row-level-security
  policy all exist, then update the list in the same patch. A failure in the action, policy,
  or row-level-security tests is a tenancy or integrity regression — treat it as a security
  defect and fix the resource, not the assertion.
  """

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

  # The complete set of configured Ash domains. Order is the configured order and is asserted
  # verbatim against application configuration, so a domain added to one place and not the
  # other is caught here.
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

  # Every durable resource the domains may expose, sorted. This is the authoritative census of
  # what may hold persistent state; anything storing durable data outside this list is writing
  # behind the Ash boundary and escapes tenancy, policy, and audit.
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

  # Every table that must carry the Account wall in the database itself: `accounts` plus each
  # table with an `account_id` column. A tenant table missing from this list would still be
  # filtered by Ash policies in normal operation, but would be readable by anything that
  # reaches PostgreSQL another way. The assertion below proves every listed table has the
  # policy; keeping the list complete when a tenant table is added is a review obligation.
  @rls_tables ~w(
    accounts api_keys attributions audit_events connector_configs document_chunks document_versions
    documents entities entity_mentions erasure_requests external_identities gate_decisions
    governance_gate_rules knowledge_consents knowledge_items knowledge_lifecycle_events
    knowledge_relations messages model_role_configs peer_ask_preferences peer_queries
    peer_query_deliveries peers pipeline_runs policy_configs projections provenances
    retrieval_profiles role_grants scope_relations scopes session_participants session_scopes
    sessions skill_requirement_cards usage_events validation_items
  )

  # Removes every credential a provider could pick up, so the seed ingests below cannot reach
  # a network endpoint: this suite is about the data boundary, and no assertion should depend
  # on a live model. Both values are global to the node, hence the capture/restore and
  # `async: false`.
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

  # Equality in both directions is the point: a resource present in a domain but missing from
  # the list fails, and a listed resource that no domain exposes fails too. Neither direction
  # may be softened into a subset check, or the tripwire stops firing.
  test "the F1 resource inventory is registered across the modular Ash domains" do
    resources =
      @domains
      |> Enum.flat_map(&Ash.Domain.Info.resources/1)
      |> Enum.sort()

    assert resources == Enum.sort(@resources)
    assert Application.fetch_env!(:cartulary, :ash_domains) == @domains
  end

  # Two independent Accounts, each with one scope and one ingested observation, so that a
  # cross-Account read has something it could wrongly return.
  test "Ash actions enforce the Account wall and governance separation" do
    seed!("f1-action-a", "/f1/action/a")
    seed!("f1-action-b", "/f1/action/b")

    {account_a, actor_a} =
      DataLayer.with_account_key("f1-action-a", fn account, actor -> {account, actor} end)

    {account_b, _actor_b} =
      DataLayer.with_account_key("f1-action-b", fn account, actor -> {account, actor} end)

    # Naming a foreign tenant on the query is exactly the attack this wall exists for: the
    # Account comes from the actor's identity, so the request parameter buys nothing and the
    # read comes back empty rather than raising. Any row here is a cross-Account data leak.
    assert [] =
             Scope
             |> Ash.Query.set_tenant(account_b.id)
             |> Ash.read!(actor: actor_a)

    visible_scope_id = scope_id!("f1-action-a", "/f1/action/a")
    scope_limited_actor = Actor.for_account(account_a, scope_ids: [visible_scope_id])

    # Inside the right Account, an actor whose grants cover only one scope still sees only that
    # scope. Account isolation and scope authorization are separate filters and both apply.
    assert [%Scope{path: "/f1/action/a"}] =
             Scope
             |> Ash.Query.set_tenant(account_a.id)
             |> Ash.read!(actor: scope_limited_actor)

    # Knowledge has exactly one writer: the extraction pipeline. An ordinary member actor
    # holding a valid Account and a scope it can read still cannot mint a statement, because
    # anything written this way would skip extraction provenance and governance review.
    assert {:error, _forbidden} =
             KnowledgeItem
             |> Ash.Changeset.for_create(:create_from_pipeline, %{
               scope_id: visible_scope_id,
               statement: "A member attempted to bypass the knowledge pipeline."
             })
             |> Ash.Changeset.set_tenant(account_a.id)
             |> Ash.create(actor: actor_a)

    # Governance configuration is administrator-only. If a member could write a policy row it
    # could widen its own gates, so the same create must fail for a member and succeed for an
    # administrator of the same Account — the difference is the role, nothing else.
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
    # Observations are written once. The single destroy action is subject erasure, which is a
    # deliberate right-to-be-forgotten path, not an ordinary delete; the one update action
    # accepts only `extraction_completed_at`, not the stored content. A second destroy action
    # appearing here would mean raw history became routinely deletable.
    assert action_types(Message) == [:create, :destroy, :read, :update]
    assert Ash.Resource.Info.action(Message, :erase).type == :destroy

    # Lifecycle and audit are ledgers: create and read only. With no update or destroy action
    # there is no supported way to rewrite or drop history, which is what makes the audit
    # hash chain and the lifecycle trail worth anything.
    assert action_types(LifecycleEvent) == [:create, :read]
    assert action_types(AuditEvent) == [:create, :read]

    # A knowledge statement is fixed at mint time. Merging duplicates and moving an item
    # through its lifecycle must not be able to swap the text underneath an existing id, or
    # every citation, decision, and audit hash referring to that id would silently change
    # meaning. Correcting a statement is instead a new item that supersedes the old one.
    refute :statement in action_accept(KnowledgeItem, :merge_from_pipeline)
    refute :statement in action_accept(KnowledgeItem, :transition)
    assert :statement in action_accept(KnowledgeItem, :create_from_pipeline)
  end

  test "Postgres RLS filters reads and rejects cross-Account writes for a non-owner role" do
    seed!("f1-rls-a", "/f1/rls/a")
    seed!("f1-rls-b", "/f1/rls/b")

    account_a_id = account_id!("f1-rls-a")
    account_b_id = account_id!("f1-rls-b")

    # Role names are cluster-wide, so the name is made unique to avoid colliding with a role
    # leaked by an earlier run. Role creation is transactional and the sandbox rolls the whole
    # test back, so nothing needs to drop it.
    role = "cartulary_rls_#{System.unique_integer([:positive])}"

    # Catalog check, not a behaviour check: every walled table must have row security enabled
    # (relrowsecurity), forced so the table owner is subject to it too (relforcerowsecurity),
    # and carry the one named Account policy. Enabled-but-not-forced would silently do nothing
    # for the role a release normally connects as.
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

    # Switch the connection to an unprivileged role for the rest of the transaction. Row-level
    # security never applies to a superuser or a role with the bypass attribute, and test and
    # migration connections are usually privileged, so without this switch the queries below
    # would prove nothing. SET LOCAL lasts until the end of the transaction, which under the
    # test sandbox is the end of the test.
    sql!("CREATE ROLE #{role} NOLOGIN")
    sql!("GRANT USAGE ON SCHEMA public TO #{role}")
    sql!("GRANT SELECT, INSERT ON accounts, scopes TO #{role}")
    sql!("SET LOCAL ROLE #{role}")

    # This is how an Account is declared to the database: a transaction-local setting (the
    # third argument makes it local) that the policy compares each row against. It is set by
    # the Account-scoped transaction helper in production, never taken from user input.
    Ecto.Adapters.SQL.query!(
      Repo,
      "SELECT set_config('cartulary.account_id', $1, true)",
      [account_a_id]
    )

    # The query asks for both scopes by path and no Account filter at all. Only the current
    # Account's row may come back; the other one must be invisible at the database level.
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

    # The wall blocks writes as well as reads: inserting a row stamped with a different Account
    # violates the policy's check clause and PostgreSQL refuses it. Without this, a compromised
    # or buggy caller could plant rows inside another tenant even though it could not read them.
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

  # Creates an Account, its scope chain, a peer, a session, and one observation by going
  # through the ordinary ingest path, so the fixtures are built the same way production data is
  # rather than by inserting rows behind the Ash boundary this suite is testing.
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

  # The distinct action kinds a resource exposes, sorted, so an assertion can state the whole
  # surface: a resource with no destroy action simply has no supported way to delete a row.
  defp action_types(resource) do
    resource
    |> Ash.Resource.Info.actions()
    |> Enum.map(& &1.type)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # The attributes an action will take from caller input. An attribute absent from this list
  # cannot be set through that action no matter what the caller sends.
  defp action_accept(resource, action_name) do
    resource
    |> Ash.Resource.Info.action(action_name)
    |> Map.fetch!(:accept)
  end

  # Direct SQL on purpose: the row-level-security test needs the raw identifiers before it
  # switches to the unprivileged role, and reading them through Ash would install tenancy
  # state that the test is trying to exercise from the database side.
  defp account_id!(key) do
    %{rows: [[id]]} =
      Ecto.Adapters.SQL.query!(Repo, "SELECT id::text FROM accounts WHERE key = $1", [key])

    id
  end

  # Joins through `accounts` rather than trusting the path alone: scope paths are unique only
  # within an Account, so two Accounts in this suite can legitimately share one.
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

  # Runs a parameterless statement. Only used for role and grant management in this file; the
  # interpolated role name is a locally generated identifier, never caller-supplied input.
  defp sql!(statement), do: Ecto.Adapters.SQL.query!(Repo, statement, [])
end
