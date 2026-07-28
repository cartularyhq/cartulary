# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.F7RetrievalEntityContextTest.Provider do
  @moduledoc false

  @behaviour Cartulary.Model.Provider

  alias Cartulary.Model.Provider.Result
  alias Cartulary.Model.Providers.Deterministic

  @impl true
  def structured(config, messages, schema, opts) do
    record(:structured)
    Deterministic.structured(config, messages, schema, opts)
  end

  @impl true
  def chat(config, messages, opts) do
    record(:chat)
    Deterministic.chat(config, messages, opts)
  end

  @impl true
  def embed(_config, texts, _opts) do
    record(:embed)

    vectors =
      Enum.map(texts, fn text ->
        normalized = String.downcase(text)

        [
          if(String.contains?(normalized, "avery"), do: 1.0, else: 0.0),
          if(String.contains?(normalized, "release"), do: 1.0, else: 0.0),
          min(String.length(normalized) / 100.0, 1.0)
        ]
      end)

    {:ok,
     %Result{
       value: vectors,
       usage: %{embedding_tokens: length(texts)},
       metadata: %{fixture: true}
     }}
  end

  @impl true
  def rerank(config, query, documents, opts) do
    record(:rerank)
    Deterministic.rerank(config, query, documents, opts)
  end

  def start! do
    {:ok, _pid} = Agent.start_link(fn -> [] end, name: __MODULE__)
  end

  def reset!, do: Agent.update(__MODULE__, fn _calls -> [] end)
  def calls, do: Agent.get(__MODULE__, &Enum.reverse/1)

  def stop do
    if Process.whereis(__MODULE__), do: Agent.stop(__MODULE__)
  end

  defp record(call), do: Agent.update(__MODULE__, &[call | &1])
end

defmodule Cartulary.F7RetrievalEntityContextTest do
  use Cartulary.DataCase, async: false

  alias Cartulary.Actor
  alias Cartulary.Context.Builder
  alias Cartulary.DataLayer
  alias Cartulary.Governance.Engine, as: GovernanceEngine
  alias Cartulary.Knowledge.{Entity, EntityMention, KnowledgeItem, KnowledgeRelation}
  alias Cartulary.Memory
  alias Cartulary.Retrieval.{EntityResolver, Indexer, Profile, Query}
  alias Cartulary.Retrieval.Strategies
  alias Cartulary.Topology.{Scope, ScopeRelation}

  require Ash.Query

  @strategies [
    Strategies.Semantic,
    Strategies.Lexical,
    Strategies.Temporal,
    Strategies.SalienceRecency,
    Strategies.EntityMatch,
    Strategies.RelationExpand
  ]

  setup do
    original_provider = Application.get_env(:cartulary, :model_provider)
    original_roles = Application.fetch_env!(:cartulary, :model_roles)
    original_retrieval = Application.fetch_env!(:cartulary, :retrieval_profiles)

    roles =
      Keyword.update!(original_roles, :embedder, fn config ->
        config
        |> Map.put(:provider, "fixture")
        |> Map.put(:model, "f7-fixture")
        |> Map.put(:model_version, "1")
        |> Map.put(:embedding_dimensions, 3)
      end)

    Application.put_env(
      :cartulary,
      :model_provider,
      Cartulary.F7RetrievalEntityContextTest.Provider
    )

    Application.put_env(:cartulary, :model_roles, roles)
    Cartulary.F7RetrievalEntityContextTest.Provider.start!()

    on_exit(fn ->
      Cartulary.F7RetrievalEntityContextTest.Provider.stop()
      Application.put_env(:cartulary, :model_roles, original_roles)
      Application.put_env(:cartulary, :retrieval_profiles, original_retrieval)

      if original_provider do
        Application.put_env(:cartulary, :model_provider, original_provider)
      else
        Application.delete_env(:cartulary, :model_provider)
      end
    end)

    :ok
  end

  test "all shipped strategies satisfy the independent contract and profile stages" do
    assert Enum.map(@strategies, & &1.name()) == [
             :semantic,
             :lexical,
             :temporal,
             :salience_recency,
             :entity_match,
             :relation_expand
           ]

    assert Enum.all?(@strategies, &(&1.cost_class() in [:cheap, :moderate, :expensive]))
    assert Enum.all?(@strategies, &(&1.stage() in [:seed, :expand]))
    assert Strategies.RelationExpand.stage() == :expand

    query = %Query{text: "release", target: :knowledge, seed_ids: ["seed"]}
    assert Enum.all?(@strategies, &is_boolean(&1.applicable?(query)))
  end

  test "semantic, lexical, temporal, and salience candidates fuse with pinned identity" do
    seeded = seed_active!("f7-fusion", "/f7/fusion", "Avery prefers concise release summaries.")

    assert {:ok, %{indexed: 1}} = Indexer.rebuild_scope(seeded.account.id, seeded.scope.id)

    result =
      Memory.search(%{
        "account_key" => "f7-fusion",
        "scope_path" => seeded.scope.path,
        "query" => "Avery release summaries",
        "deadline" => "disabled"
      })

    assert result["profile"] == "balanced"
    assert result["profile_version"] == "f7-1"
    assert result["dropped_strategies"] == []
    assert "semantic" in result["contributed_strategies"]
    assert "lexical" in result["contributed_strategies"]

    assert [%{"id" => id, "strategies" => strategies} | _] = result["candidates"]
    assert id == seeded.knowledge.id
    assert "semantic" in strategies
    assert "lexical" in strategies

    assert [] ==
             Memory.search(%{
               "account_key" => "f7-fusion",
               "scope_path" => seeded.scope.path,
               "query" => "Avery release summaries",
               "strategies" => ["lexical"],
               "source_filters" => %{"model" => "not-the-extracting-model"},
               "deadline" => "disabled"
             })["candidates"]

    assert %{rows: [["vector", 3]]} =
             Ecto.Adapters.SQL.query!(
               Repo,
               """
               SELECT pg_typeof(embedding)::text, vector_dims(embedding)
               FROM knowledge_items
               WHERE id = $1
               """,
               [Ecto.UUID.dump!(seeded.knowledge.id)]
             )
  end

  test "relation expansion traverses knowledge relations and shared-entity edges" do
    first = seed_active!("f7-expand", "/f7/expand", "Orchid uses an append-only ledger.")

    second =
      seed_active!(
        "f7-expand",
        "/f7/expand",
        "Saturday is the production deployment window.",
        "session-2"
      )

    DataLayer.with_account_key("f7-expand", fn account, actor ->
      create!(
        KnowledgeRelation,
        :create_from_pipeline,
        %{
          scope_id: first.scope.id,
          source_knowledge_id: first.knowledge.id,
          target_knowledge_id: second.knowledge.id,
          kind: "supports",
          confidence: 0.9
        },
        account.id,
        pipeline_actor(actor)
      )
    end)

    result =
      Memory.search(%{
        "account_key" => "f7-expand",
        "scope_path" => "/f7/expand",
        "query" => "Orchid append-only ledger",
        "profile" => "thorough",
        "strategies" => ["lexical", "relation_expand"],
        "deadline" => "disabled"
      })

    assert second.knowledge.id in Enum.map(result["candidates"], & &1["id"])
    assert "relation_expand" in result["contributed_strategies"]
  end

  test "entity resolution is internal, alias retrieval is scoped, and public surfaces stay opaque" do
    seeded = seed_active!("f7-entity", "/f7/entity", "Avery owns the release checklist.")

    assert {:ok, %{mentions: mentions}} =
             EntityResolver.rebuild_scope(seeded.account.id, seeded.scope.id)

    assert mentions >= 1

    DataLayer.with_account_key("f7-entity", fn account, actor ->
      pipeline = pipeline_actor(actor)

      entity =
        Entity
        |> Ash.Query.filter(canonical_name == "Avery")
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read_one!(actor: pipeline)

      entity
      |> Ash.Changeset.for_update(:recompute_from_pipeline, %{aliases: ["Avery", "Av"]})
      |> Ash.Changeset.set_tenant(account.id)
      |> Ash.update!(actor: pipeline, authorize?: false)
    end)

    result =
      Memory.search(%{
        "account_key" => "f7-entity",
        "scope_path" => "/f7/entity",
        "query" => "Av",
        "strategies" => ["entity_match"],
        "deadline" => "disabled"
      })

    assert [%{"id" => id} = candidate | _] = result["candidates"]
    assert id == seeded.knowledge.id
    refute Map.has_key?(candidate, "canonical_name")
    refute Map.has_key?(candidate, "aliases")
    refute Map.has_key?(candidate, "entity_id")

    refute :canonical_name in Enum.map(Ash.Resource.Info.public_attributes(Entity), & &1.name)
    refute :aliases in Enum.map(Ash.Resource.Info.public_attributes(Entity), & &1.name)

    refute :surface_form in Enum.map(
             Ash.Resource.Info.public_attributes(EntityMention),
             & &1.name
           )

    refute Enum.any?(CartularyWeb.Router.__routes__(), fn route ->
             String.contains?(route.path, "entit")
           end)
  end

  test "Account and authorized scope filters run before candidates leave retrieval" do
    visible = seed_active!("f7-wall-a", "/f7/team/visible", "Visible Orchid handbook.")
    _hidden = seed_active!("f7-wall-a", "/f7/team/hidden", "Hidden Juniper handbook.")
    _foreign = seed_active!("f7-wall-b", "/f7/team/visible", "Foreign Juniper handbook.")

    result =
      Memory.search(%{
        "account_key" => "f7-wall-a",
        "scope_path" => visible.scope.path,
        "query" => "Juniper handbook",
        "strategies" => ["lexical"],
        "deadline" => "disabled"
      })

    assert result["candidates"] == []
  end

  test "nearest-scope profile inheritance, raw overrides, and deadline reporting are explicit" do
    seeded = seed_active!("f7-profile", "/f7/profile/child", "Avery writes release notes.")

    parent =
      DataLayer.with_account_key("f7-profile", fn account, actor ->
        Scope
        |> Ash.Query.filter(path == "/f7/profile")
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read_one!(actor: actor)
      end)

    DataLayer.with_account_key("f7-profile", fn account, actor ->
      actor = %{actor | role: :account_admin}

      create!(
        Cartulary.Retrieval.RetrievalProfile,
        :create,
        %{
          scope_id: parent.id,
          name: "balanced",
          version: 1,
          strategy_config: %{"strategies" => ["temporal"], "weights" => %{"temporal" => 1}},
          deadline_ms: 222,
          active: true
        },
        account.id,
        actor
      )

      create!(
        Cartulary.Retrieval.RetrievalProfile,
        :create,
        %{
          scope_id: seeded.scope.id,
          name: "balanced",
          version: 2,
          strategy_config: %{"strategies" => ["lexical"], "weights" => %{"lexical" => 1}},
          deadline_ms: 111,
          active: true
        },
        account.id,
        actor
      )

      query = %Query{
        account_id: account.id,
        actor: actor,
        scope_ids: [seeded.scope.id, parent.id],
        text: "release",
        target: :knowledge
      }

      profile = Profile.resolve(:balanced, query)
      assert profile.strategies == [:lexical]
      assert profile.deadline_ms == 111
      assert profile.version =~ ~r/\Af7-2-[0-9a-f]{10}\z/

      assert_raise ArgumentError, ~r/raw retrieval strategies/, fn ->
        Profile.resolve(:balanced, query, strategies: [:temporal], internal?: false)
      end
    end)

    _deadline_seed =
      seed_active!("f7-deadline", "/f7/deadline", "Avery publishes release notes.")

    retrieval = Application.fetch_env!(:cartulary, :retrieval_profiles)

    Application.put_env(
      :cartulary,
      :retrieval_profiles,
      Keyword.update!(retrieval, :balanced, &Map.put(&1, :deadline_ms, 0))
    )

    result =
      Memory.search(%{
        "account_key" => "f7-deadline",
        "scope_path" => "/f7/deadline",
        "query" => "release"
      })

    assert result["candidates"] == []
    assert "lexical" in result["dropped_strategies"]
  end

  test "projection refresh, bounded deltas, session resolution, and ETS invalidation stay model-free" do
    seeded =
      seed_active!(
        "f7-context",
        "/f7/context",
        "Avery prefers concise release summaries.",
        "context-session"
      )

    assert {:ok, %{scope_card: _id}} =
             Builder.refresh_scope(seeded.account.id, seeded.scope.id)

    Cartulary.F7RetrievalEntityContextTest.Provider.reset!()

    first =
      Memory.get_context(
        %{
          "scope_path" => seeded.scope.path,
          "session_id" => "context-session",
          "budget_chars" => 20_000
        },
        seeded.actor
      )

    second =
      Memory.get_context(
        %{
          "scope_path" => seeded.scope.path,
          "session_id" => "context-session",
          "budget_chars" => 20_000
        },
        seeded.actor
      )

    assert first["profile_version"] == "f7-1"
    assert first["fast_fallback"] == false
    assert first["session_summary"]["session_id"]
    assert [%{"path" => "/f7/context"} | _] = first["scope_cards"]
    assert [%{"statement" => statement} | _] = first["peer_profile"]
    assert statement =~ "concise release summaries"
    assert second["projection_cache_hit"] == true
    assert Cartulary.F7RetrievalEntityContextTest.Provider.calls() == []

    DataLayer.with_account_key("f7-context", fn account, actor ->
      Builder.mark_dirty(account.id, pipeline_actor(actor), seeded.scope.id)
    end)

    dirty =
      Memory.get_context(
        %{"scope_path" => seeded.scope.path, "query" => "release"},
        seeded.actor
      )

    assert dirty["fast_fallback"] == true
  end

  test "F7 migration installs FTS and pgvector ANN indexes" do
    assert %{rows: rows} =
             Ecto.Adapters.SQL.query!(
               Repo,
               """
               SELECT indexname
               FROM pg_indexes
               WHERE indexname = ANY($1)
               ORDER BY indexname
               """,
               [
                 [
                   "document_chunks_search_vector_idx",
                   "document_chunks_embedding_hnsw_384_idx",
                   "entities_alias_embedding_hnsw_384_idx",
                   "knowledge_items_embedding_hnsw_384_idx",
                   "knowledge_items_search_vector_idx"
                 ]
               ]
             )

    assert Enum.map(rows, &hd/1) == [
             "document_chunks_embedding_hnsw_384_idx",
             "document_chunks_search_vector_idx",
             "entities_alias_embedding_hnsw_384_idx",
             "knowledge_items_embedding_hnsw_384_idx",
             "knowledge_items_search_vector_idx"
           ]
  end

  test "cross-linked scope reads still require access to both relation endpoints" do
    seeded = seed_active!("f7-scope-link", "/f7/link/source", "Source scope memory.")
    hidden = seed_active!("f7-scope-link", "/f7/link/hidden", "Hidden scope memory.")

    DataLayer.with_account_key("f7-scope-link", fn account, actor ->
      create!(
        ScopeRelation,
        :create,
        %{
          source_scope_id: seeded.scope.id,
          target_scope_id: hidden.scope.id,
          kind: "related",
          metadata: %{}
        },
        account.id,
        actor
      )
    end)

    system_result =
      Memory.search(%{
        "account_key" => "f7-scope-link",
        "scope_path" => seeded.scope.path,
        "query" => "Source scope memory",
        "include_cross_links" => true,
        "strategies" => ["lexical", "relation_expand"],
        "deadline" => "disabled"
      })

    assert hidden.knowledge.id in Enum.map(system_result["candidates"], & &1["id"])

    limited_actor = %{seeded.actor | role: :reader, scope_ids: [seeded.scope.id]}

    limited_result =
      Memory.search(
        %{
          "scope_path" => seeded.scope.path,
          "query" => "Source scope memory",
          "include_cross_links" => true,
          "profile" => "thorough",
          "deadline" => "disabled"
        },
        limited_actor
      )

    refute hidden.knowledge.id in Enum.map(limited_result["candidates"], & &1["id"])
  end

  defp seed_active!(account_key, scope_path, statement, session_id \\ "session-1") do
    assert {:ok, message} =
             Memory.ingest_message(%{
               "account_key" => account_key,
               "session_id" => session_id,
               "scope_path" => scope_path,
               "peer_key" => "avery",
               "peer_name" => "Avery",
               "content" => statement
             })

    knowledge_id = message["knowledge"] |> hd() |> Map.fetch!("id")

    DataLayer.with_account_key(account_key, fn account, actor ->
      scope =
        Scope
        |> Ash.Query.filter(path == ^scope_path)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read_one!(actor: actor)

      knowledge =
        KnowledgeItem
        |> Ash.Query.filter(id == ^knowledge_id)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read_one!(actor: actor)

      peer = read_peer!(account.id, actor)
      actor = %{actor | peer_id: peer.id}
      pipeline = pipeline_actor(actor)

      knowledge =
        GovernanceEngine.transition!(
          knowledge,
          pipeline,
          %{state: "active", verification: "auto_verified"},
          reason: "f7_test_activate",
          channel: "pipeline"
        )

      %{account: account, actor: actor, scope: scope, knowledge: knowledge}
    end)
  end

  defp read_peer!(account_id, actor) do
    Cartulary.Accounts.Peer
    |> Ash.Query.filter(key == "avery")
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read_one!(actor: actor)
  end

  defp pipeline_actor(%Actor{} = actor),
    do: %{actor | role: :system, pipeline?: true, scope_ids: :all}

  defp create!(resource, action, attrs, account_id, actor) do
    resource
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_tenant(account_id)
    |> Ash.Changeset.for_create(action, attrs)
    |> Ash.create!(actor: actor)
  end
end
