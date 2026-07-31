# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.F7RetrievalEntityContextTest.Provider do
  @moduledoc """
  Deterministic, call-recording provider for retrieval tests.

  Structured generation, chat, and rerank delegate offline; embeddings use two
  keyword flags plus normalized text length so semantic order is predictable.
  A named Agent records calls, allowing context tests to prove the cached path
  is model-free. The singleton recorder requires synchronous tests.
  """

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

  # Interpretable dimensions make nearest-neighbor expectations explicit.
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

  @doc "Starts the call recorder. One per node; the suite must be `async: false`."
  def start! do
    {:ok, _pid} = Agent.start_link(fn -> [] end, name: __MODULE__)
  end

  @doc "Clears the recorded calls. Call this right before the window you intend to assert on."
  def reset!, do: Agent.update(__MODULE__, fn _calls -> [] end)

  @doc "Returns the recorded capability atoms in call order (the agent stores them reversed)."
  def calls, do: Agent.get(__MODULE__, &Enum.reverse/1)

  @doc "Stops the recorder. Must run in `on_exit` so the next test starts from empty."
  def stop do
    if Process.whereis(__MODULE__), do: Agent.stop(__MODULE__)
  end

  defp record(call), do: Agent.update(__MODULE__, &[call | &1])
end

defmodule Cartulary.F7RetrievalEntityContextTest.VanishingProvider do
  @moduledoc """
  Failure-injection provider for rebuild transaction boundaries.

  Embed deletes the knowledge row due for indexing; structured generation
  deletes the entity due for folding. The subsequent write must fail while the
  separately committed usage event survives. Raw SQL performs the mid-provider
  deletion under the sandbox's Account RLS setting. Unused chat and rerank calls
  fail explicitly.
  """

  @behaviour Cartulary.Model.Provider

  alias Cartulary.Model.Provider.Result
  alias Cartulary.Repo

  @impl true
  def structured(_config, [%{content: content}], _schema, _opts) do
    canonical_name = content |> String.split("right=") |> List.last()

    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM entities WHERE canonical_name = $1", [
      canonical_name
    ])

    {:ok,
     %Result{
       value: %{"same_entity" => true},
       usage: %{input_tokens: 11, output_tokens: 1},
       metadata: %{}
     }}
  end

  @impl true
  def chat(_config, _messages, _opts), do: {:error, :not_supported}

  @impl true
  def embed(_config, texts, _opts) do
    Enum.each(texts, fn text ->
      Ecto.Adapters.SQL.query!(Repo, "DELETE FROM knowledge_items WHERE statement = $1", [
        text
      ])
    end)

    # Cosine 0.8 puts Oryon in the resolver's ambiguous adjudication band.
    vectors =
      Enum.map(texts, fn
        "Oryon" -> [0.8, 0.6, 0.0]
        _other -> [1.0, 0.0, 0.0]
      end)

    {:ok, %Result{value: vectors, usage: %{embedding_tokens: length(texts)}, metadata: %{}}}
  end

  @impl true
  def rerank(_config, _query, _documents, _opts), do: {:error, :not_supported}
end

defmodule Cartulary.F7RetrievalEntityContextTest.UnavailableEmbedderProvider do
  @moduledoc """
  Provider whose embedder is down and whose other capabilities are not.

  Used to prove that a failed embedding call degrades one strategy and is
  reported, rather than passing as a query that legitimately matched nothing.
  """

  @behaviour Cartulary.Model.Provider

  alias Cartulary.Model.Providers.Deterministic

  @impl true
  def structured(config, messages, schema, opts),
    do: Deterministic.structured(config, messages, schema, opts)

  @impl true
  def chat(config, messages, opts), do: Deterministic.chat(config, messages, opts)

  @impl true
  def embed(_config, _texts, _opts), do: {:error, :embedder_unavailable}

  @impl true
  def rerank(config, query, documents, opts),
    do: Deterministic.rerank(config, query, documents, opts)
end

defmodule Cartulary.F7RetrievalEntityContextTest do
  @moduledoc """
  Pins retrieval, private entity caches, and reasoning-free context assembly.

  The suite protects strategy contracts, rank fusion, in-query authorization,
  entity invisibility, nearest-wins versioned profiles, internal-only raw
  strategy selection, enforced/reported deadlines, model-free cached context,
  and authorization at both cross-scope endpoints. Account/scope leakage or
  public entity data is a security failure.

  `f7-1` identifies retrieval and context behavior in search, ask, and context
  responses; changing it requires a changelog and updated evidence. The suite
  runs synchronously because it changes node-global retrieval/model settings
  and uses a singleton recorder.
  """

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

  # Every strategy Cartulary ships. Listing them here rather than reading a registry means a
  # newly added strategy makes this suite fail until someone states what it is and how it
  # behaves, which is the intended review prompt.
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

    # Three dimensions, matching the recording provider's hand-built vectors. Production uses
    # 384; the small space keeps semantic ranking predictable in assertions.
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

    # Retrieval profiles are restored too: one test deliberately sets a zero-millisecond
    # deadline, and leaving that in place would make every later test return nothing.
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

    # Cost class drives which strategies a deadline-bounded profile is willing to run.
    assert Enum.all?(@strategies, &(&1.cost_class() in [:cheap, :moderate, :expensive]))
    # Stage is an ordering constraint, not a label: seed strategies find candidates from the
    # query, expansion strategies walk outward from the seed head and therefore cannot run
    # until seeding finishes. Relation expansion is the one expansion strategy shipped.
    assert Enum.all?(@strategies, &(&1.stage() in [:seed, :expand]))
    assert Strategies.RelationExpand.stage() == :expand

    # Applicability must be a cheap, total predicate: it is consulted for every query, so it
    # cannot query the database or raise on an unusual query shape.
    query = %Query{text: "release", target: :knowledge, seed_ids: ["seed"]}
    assert Enum.all?(@strategies, &is_boolean(&1.applicable?(query)))
  end

  test "semantic, lexical, temporal, and salience candidates fuse with pinned identity" do
    seeded = seed_active!("f7-fusion", "/f7/fusion", "Avery prefers concise release summaries.")

    # Vectors and full-text data are a rebuildable cache. Rebuilding the scope explicitly
    # keeps the test independent of background job timing.
    assert {:ok, %{indexed: 1}} = Indexer.rebuild_scope(seeded.account.id, seeded.scope.id)

    result =
      Memory.search(%{
        "account_key" => "f7-fusion",
        "scope_path" => seeded.scope.path,
        "query" => "Avery release summaries",
        # Deadlines off: this test is about fusion, and a timing-sensitive assertion would
        # be flaky on a loaded CI machine. Deadline behaviour has its own test below.
        "deadline" => "disabled"
      })

    assert result["profile"] == "balanced"
    assert result["profile_version"] == "f7-1"
    # Nothing was dropped, so the result set is complete — this is what makes the following
    # candidate assertions meaningful rather than accidental.
    assert result["dropped_strategies"] == []
    assert "semantic" in result["contributed_strategies"]
    assert "lexical" in result["contributed_strategies"]

    # The same statement found by two independent strategies is reported once, carrying the
    # list of strategies that found it. Callers use that as an agreement signal.
    assert [%{"id" => id, "strategies" => strategies} | _] = result["candidates"]
    assert id == seeded.knowledge.id
    assert "semantic" in strategies
    assert "lexical" in strategies

    # Source filters are applied inside retrieval, before fusion. Filtering on a model that
    # did not extract this item must remove it entirely, not merely rank it lower.
    assert [] ==
             Memory.search(%{
               "account_key" => "f7-fusion",
               "scope_path" => seeded.scope.path,
               "query" => "Avery release summaries",
               "strategies" => ["lexical"],
               "source_filters" => %{"model" => "not-the-extracting-model"},
               "deadline" => "disabled"
             })["candidates"]

    # The column is a real pgvector `vector`, not a float array stand-in. Only the true type
    # can use the approximate-nearest-neighbour index; an array would silently fall back to a
    # full scan and quietly become unusable as the corpus grows.
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

  test "lexical ranks a target above distractors that share only part of the query" do
    corpus = seed_ranking_corpus!()

    result =
      Memory.search(%{
        "account_key" => "f7-rank",
        "scope_path" => "/f7/rank",
        # Every content word of the query appears in the target statement; each distractor
        # holds a strict subset. Ranking, not membership, is what separates them.
        "query" => "Avery release checklist",
        # Lexical alone, so the ordering asserted below is the lexical predicate's own and
        # cannot be supplied by a strategy that ignores the query text.
        "strategies" => ["lexical"],
        "deadline" => "disabled"
      })

    ids = Enum.map(result["candidates"], & &1["id"])

    assert [%{"id" => head_id, "strategies" => strategies} | _] = result["candidates"]
    assert head_id == corpus.target.knowledge.id
    # The per-candidate attribution, not `contributed_strategies`: an empty lexical list is
    # still reported as a contributor, so only this field distinguishes a hit from a miss.
    assert "lexical" in strategies

    # Sharing no query term is the one thing that must keep a statement out of the lexical
    # list. Were that to fail, the ordering above would be measuring an unfiltered scan.
    refute corpus.unrelated.knowledge.id in ids

    # Whichever partial-overlap distractors the predicate admits, none may outrank the only
    # statement carrying every query term.
    for distractor <- [corpus.shared_person_and_artifact, corpus.shared_artifact],
        distractor.knowledge.id in ids do
      assert Enum.find_index(ids, &(&1 == corpus.target.knowledge.id)) <
               Enum.find_index(ids, &(&1 == distractor.knowledge.id))
    end
  end

  test "fusion ranks the query-matching target above distractors a newer statement outranks" do
    corpus = seed_ranking_corpus!()

    result =
      Memory.search(%{
        "account_key" => "f7-rank",
        "scope_path" => "/f7/rank",
        "query" => "Avery release checklist",
        "deadline" => "disabled"
      })

    ids = Enum.map(result["candidates"], & &1["id"])

    # The whole corpus is reachable, so the positions below compare candidates that were all
    # available to be ranked first.
    assert length(ids) == 5

    assert [%{"id" => head_id, "strategies" => strategies} | _] = result["candidates"]
    assert head_id == corpus.target.knowledge.id
    assert "semantic" in strategies
    assert "lexical" in strategies

    # The target was seeded first, so recency-ordered strategies rank it last of the five.
    # Its head position therefore comes from the query-dependent strategies outweighing them,
    # which is the agreement signal fusion exists to produce.
    target_rank = Enum.find_index(ids, &(&1 == corpus.target.knowledge.id))

    for distractor <- [
          corpus.shared_person_and_artifact,
          corpus.shared_artifact,
          corpus.shared_person,
          corpus.unrelated
        ] do
      assert target_rank < Enum.find_index(ids, &(&1 == distractor.knowledge.id))
    end
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
        # The query mentions only the first statement. The second shares no keywords and no
        # embedding signal, so it can only arrive by traversing the relation just created.
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

    # Entity resolution runs as a background rebuild over governed statements. It is invoked
    # directly here so the assertions do not depend on job scheduling.
    assert {:ok, %{mentions: mentions}} =
             EntityResolver.rebuild_scope(seeded.account.id, seeded.scope.id)

    assert mentions >= 1

    # Give the resolved entity a short alias. Aliases are internal recall aids: they must be
    # usable as a query and must never be returned to a caller. Writing one requires the
    # pipeline actor because the cache has no externally reachable write action.
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

    # Searching the alias finds the statement: the cache widens recall as intended.
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
    # ...but the candidate exposes nothing about the entity that matched. Entity rows are a
    # derived, pipeline-internal cache; disclosing names, aliases, or ids would create a
    # second, ungoverned view of who and what an account knows about.
    refute Map.has_key?(candidate, "canonical_name")
    refute Map.has_key?(candidate, "aliases")
    refute Map.has_key?(candidate, "entity_id")

    # Enforced structurally, not just by response shaping: these attributes are not public on
    # the resources, so no generic API surface can serialize them by accident.
    refute :canonical_name in Enum.map(Ash.Resource.Info.public_attributes(Entity), & &1.name)
    refute :aliases in Enum.map(Ash.Resource.Info.public_attributes(Entity), & &1.name)

    refute :surface_form in Enum.map(
             Ash.Resource.Info.public_attributes(EntityMention),
             & &1.name
           )

    # And no HTTP route addresses entities at all. Substring match on purpose: it also
    # catches "entities" and "entity_mentions".
    refute Enum.any?(CartularyWeb.Router.__routes__(), fn route ->
             String.contains?(route.path, "entit")
           end)
  end

  test "Indexer.rebuild_scope keeps a billed embedding call metered when the write phase fails" do
    seeded = seed_active!("f7-index-vanish", "/f7/index-vanish", "Vanishing indexer statement.")

    original_provider = Application.get_env(:cartulary, :model_provider)

    on_exit(fn ->
      if original_provider do
        Application.put_env(:cartulary, :model_provider, original_provider)
      else
        Application.delete_env(:cartulary, :model_provider)
      end
    end)

    Application.put_env(
      :cartulary,
      :model_provider,
      Cartulary.F7RetrievalEntityContextTest.VanishingProvider
    )

    # The provider deletes the very knowledge item being indexed as a side effect of
    # answering the embedding call, so the write phase's update has no row left to update.
    # Ash reports this as forbidden rather than not-found: its policy check re-filters by
    # tenant and existence together, and a row that no longer matches either is
    # indistinguishable from one the actor was never allowed to see.
    assert_raise Ash.Error.Forbidden, fn ->
      Indexer.rebuild_scope(seeded.account.id, seeded.scope.id)
    end

    # The call was made and billed. Rolling its ledger row back with the failed write would
    # understate real spend, so the usage write must not share a transaction with the vector
    # write.
    assert scalar!(
             "SELECT count(*) FROM usage_events WHERE account_id = $1 AND model_role = 'embedder'",
             [Ecto.UUID.dump!(seeded.account.id)]
           ) == 1

    # The item is really gone — the provider deleted it — which is exactly what confirms
    # nothing else was half-written: the write phase raised before it touched any row.
    assert scalar!(
             "SELECT count(*) FROM knowledge_items WHERE id = $1",
             [Ecto.UUID.dump!(seeded.knowledge.id)]
           ) == 0
  end

  test "EntityResolver.rebuild_scope keeps billed calls metered and the prior index intact when the write phase fails" do
    seeded =
      seed_active!("f7-entity-vanish", "/f7/entity-vanish", "Oryon owns the launch checklist.")

    # A pre-existing entity from an earlier rebuild, seeded directly rather than through
    # `rebuild_scope/2` so its alias embedding is the exact vector the fixture provider's
    # "Oryon" vector sits at cosine 0.8 from — inside the ambiguous band, so this run reaches
    # the reasoning model rather than matching or rejecting on similarity alone.
    entity =
      DataLayer.with_account_key("f7-entity-vanish", fn account, actor ->
        create!(
          Entity,
          :create_from_pipeline,
          %{
            canonical_name: "Orion",
            kind: "person",
            aliases: ["Orion"],
            alias_embedding: [1.0, 0.0, 0.0],
            embedding_provider: "fixture",
            embedding_model: "f7-fixture",
            embedding_version: "1",
            embedding_dimensions: 3,
            derived_from: []
          },
          account.id,
          pipeline_actor(actor)
        )
      end)

    original_provider = Application.get_env(:cartulary, :model_provider)

    on_exit(fn ->
      if original_provider do
        Application.put_env(:cartulary, :model_provider, original_provider)
      else
        Application.delete_env(:cartulary, :model_provider)
      end
    end)

    Application.put_env(
      :cartulary,
      :model_provider,
      Cartulary.F7RetrievalEntityContextTest.VanishingProvider
    )

    # The provider deletes the adjudicated entity as a side effect of answering, so the write
    # phase's re-read of it comes back empty.
    assert_raise RuntimeError, ~r/vanished/, fn ->
      EntityResolver.rebuild_scope(seeded.account.id, seeded.scope.id)
    end

    # Both billed embedding calls — the one that scored the ambiguous match and the one that
    # re-embeds the widened alias set once the fold is decided — survive the later failure,
    # along with the reasoner call that adjudicated the match, because metering commits in its
    # own transaction rather than the rebuild's write transaction.
    assert scalar!(
             "SELECT count(*) FROM usage_events WHERE account_id = $1 AND model_role = 'embedder'",
             [Ecto.UUID.dump!(seeded.account.id)]
           ) == 2

    assert scalar!(
             "SELECT count(*) FROM usage_events WHERE account_id = $1 AND model_role = 'dream_reasoner'",
             [Ecto.UUID.dump!(seeded.account.id)]
           ) == 1

    # The write transaction rolled back entirely: clearing this scope's mentions and folding
    # the surface form into the entity happen in the same transaction as the re-read that
    # failed, so no mention was left behind by a half-applied rebuild.
    assert scalar!(
             "SELECT count(*) FROM entity_mentions WHERE scope_id = $1",
             [Ecto.UUID.dump!(seeded.scope.id)]
           ) == 0

    # The entity really is gone — the provider deleted it — which is what forced the write
    # phase to fail in the first place, not evidence the transaction misbehaved.
    assert scalar!(
             "SELECT count(*) FROM entities WHERE id = $1",
             [Ecto.UUID.dump!(entity.id)]
           ) == 0
  end

  test "Account and authorized scope filters run before candidates leave retrieval" do
    # Three statements, two traps. The query matches "Juniper handbook", which appears only
    # in a sibling scope of the same account and in a different account entirely. The one
    # statement in the searched scope does not match the query.
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

    # Empty is the only correct answer. Scope containment inherits downward, never sideways,
    # and account isolation is absolute. A non-empty result here is a data-leak bug, not a
    # ranking bug — do not "fix" it by adjusting the query or the fixtures.
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
      # Authoring a retrieval profile is an administrative act, not something a reader or a
      # machine credential may do; it changes what every caller in the subtree sees.
      actor = %{actor | role: :account_admin}

      # Parent scope: temporal only, 222 ms deadline. Deliberately different in both strategy
      # set and deadline from the child, so the resolution assertions cannot both pass by
      # accident.
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

      # Child scope, same profile name: lexical only, 111 ms deadline.
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

      # Nearest scope wins outright — the child's configuration is used, not merged with the
      # parent's. Both scopes are in the query, so this cannot be an accident of filtering.
      profile = Profile.resolve(:balanced, query)
      assert profile.strategies == [:lexical]
      assert profile.deadline_ms == 111

      # The reported version is the authored version plus a digest of the effective
      # strategies, weights, and rerank settings. Two runs reporting the same version really
      # did use the same configuration, even if someone edited a profile in place without
      # bumping its number. Only the shape is asserted; the digest changes with the config.
      assert profile.version =~ ~r/\Af7-2-[0-9a-f]{10}\z/

      # An external caller cannot hand-pick strategies. Named profiles are what make a
      # published measurement reproducible; a raw list from a request would not be.
      assert_raise ArgumentError, ~r/raw retrieval strategies/, fn ->
        Profile.resolve(:balanced, query, strategies: [:temporal], internal?: false)
      end
    end)

    _deadline_seed =
      seed_active!("f7-deadline", "/f7/deadline", "Avery publishes release notes.")

    retrieval = Application.fetch_env!(:cartulary, :retrieval_profiles)

    # A zero-millisecond budget: nothing can finish. Restored by the suite's on_exit.
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

    # Out-of-time strategies are dropped, never retried and never waited out. The caller gets
    # an empty but *honest* answer: the response names what was dropped, so a degraded result
    # is distinguishable from a genuinely empty corpus.
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

    # Build the projections up front. Refresh is the expensive, background-time step; the
    # live context path is only allowed to read what refresh already produced.
    assert {:ok, %{scope_card: _id}} =
             Builder.refresh_scope(seeded.account.id, seeded.scope.id)

    # Start counting model calls from here. Everything after this point is the live path.
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
    # Projections were clean, so no live retrieval fallback was needed.
    assert first["fast_fallback"] == false
    # Session summary, scope cards, and peer profile are projections of governed knowledge —
    # views, not a second copy of the truth. They are assembled in a fixed budget order.
    assert first["session_summary"]["session_id"]
    assert [%{"path" => "/f7/context"} | _] = first["scope_cards"]
    assert [%{"statement" => statement} | _] = first["peer_profile"]
    assert statement =~ "concise release summaries"
    # The second identical request is served from the in-memory cache.
    assert second["projection_cache_hit"] == true
    # Zero model calls across both requests. This is the assertion that keeps context
    # assembly cheap and predictable: the moment it summarizes with a model, every agent
    # turn pays for inference and the response stops being reproducible.
    assert Cartulary.F7RetrievalEntityContextTest.Provider.calls() == []

    # Marking the scope dirty invalidates the cached projection, exactly as a lifecycle
    # change would. Invalidation is broadcast so every node in a multi-node deployment drops
    # the same key rather than serving stale context from its own memory.
    DataLayer.with_account_key("f7-context", fn account, actor ->
      Builder.mark_dirty(account.id, pipeline_actor(actor), seeded.scope.id)
    end)

    dirty =
      Memory.get_context(
        %{"scope_path" => seeded.scope.path, "query" => "release"},
        seeded.actor
      )

    # On a miss the caller still gets an answer, from the cheapest retrieval profile, and the
    # response says so. Silently serving a stale projection would be the worse failure.
    assert dirty["fast_fallback"] == true
  end

  test "index coverage separates an unindexed scope from an empty one and reports the identity" do
    seeded = seed_active!("f7-coverage", "/f7/coverage", "Avery tracks the release checklist.")

    # The scope holds a governed statement and no vectors — exactly the state a cancelled
    # projection refresh leaves behind, and the state that was previously unobservable.
    before = Cartulary.Retrieval.index_coverage(seeded.account.id, [seeded.scope.id])

    assert %{
             statement_count: 1,
             embedded_count: 0,
             mention_count: 0,
             coverage: +0.0,
             embedding_identities: []
           } = Map.fetch!(before, seeded.scope.id)

    # A scope that was never written to reads as zeros rather than as an absent key, and
    # counts as covered: there is nothing to index, so an alert on the ratio must not fire.
    empty_scope_id = Ecto.UUID.generate()
    empty = Cartulary.Retrieval.index_coverage(seeded.account.id, [empty_scope_id])

    assert %{statement_count: 0, embedded_count: 0, coverage: 1.0} =
             Map.fetch!(empty, empty_scope_id)

    events = attach_projection_refresh_telemetry!()

    assert {:ok, %{index: %{indexed: 1}}} =
             Cartulary.Retrieval.rebuild_scope(seeded.account.id, seeded.scope.id)

    after_rebuild = Cartulary.Retrieval.index_coverage(seeded.account.id, [seeded.scope.id])
    coverage = Map.fetch!(after_rebuild, seeded.scope.id)

    assert coverage.statement_count == 1
    assert coverage.embedded_count == 1
    assert coverage.coverage == 1.0
    # Mentions are reported as a count. Naming the entity, its aliases, or the matched surface
    # form here would create a second, ungoverned view of who an Account knows about.
    assert coverage.mention_count >= 1

    assert Map.keys(coverage) |> Enum.sort() == [
             :coverage,
             :embedded_count,
             :embedding_identities,
             :mention_count,
             :statement_count
           ]

    # The identity is what decides whether stored vectors are comparable at all; two of them
    # in one scope means part of it needs re-embedding.
    assert [%{provider: "fixture", model: "f7-fixture", version: "1", dimensions: 3}] =
             coverage.embedding_identities

    assert_receive {^events, measurements, metadata}
    assert measurements.indexed == 1
    assert measurements.statements == 1
    assert measurements.embedded == 1
    assert measurements.coverage == 1.0
    assert metadata.scope_id == seeded.scope.id
    assert metadata.account_id == seeded.account.id
  end

  test "an unavailable embedder drops the semantic strategy instead of reporting no matches" do
    seeded = seed_active!("f7-drop", "/f7/drop", "Avery reviews the release checklist.")

    assert {:ok, %{indexed: 1}} = Indexer.rebuild_scope(seeded.account.id, seeded.scope.id)

    original_provider = Application.get_env(:cartulary, :model_provider)

    on_exit(fn ->
      if original_provider do
        Application.put_env(:cartulary, :model_provider, original_provider)
      else
        Application.delete_env(:cartulary, :model_provider)
      end
    end)

    Application.put_env(
      :cartulary,
      :model_provider,
      Cartulary.F7RetrievalEntityContextTest.UnavailableEmbedderProvider
    )

    result =
      Memory.search(%{
        "account_key" => "f7-drop",
        "scope_path" => seeded.scope.path,
        "query" => "release checklist",
        "strategies" => ["semantic", "lexical"],
        "deadline" => "disabled"
      })

    # Semantic never ran, so it is degradation and must be reported as such. Counting it as a
    # contributing strategy that happened to find nothing is what makes an unindexed corpus
    # and a broken embedder indistinguishable from a genuinely unmatched query.
    assert "semantic" in result["dropped_strategies"]
    refute "semantic" in result["contributed_strategies"]
    # The request still answers from the strategies that did run.
    assert "lexical" in result["contributed_strategies"]
    assert [%{"id" => id} | _] = result["candidates"]
    assert id == seeded.knowledge.id
  end

  # The index names below are frozen: they are what the hand-written migration DDL created,
  # and the query planner will not use an index that has been renamed or dropped. A missing
  # index does not fail any other test — retrieval still returns correct results, just by
  # sequential scan — so this is the only place a silent performance cliff gets caught.
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

    # A caller authorized for both scopes may follow the link, so the relation demonstrably
    # works. Without this half, the second half would pass even if expansion were broken.
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

    # The same query as a reader authorized for the source scope only.
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

    # A relation between scopes is a hint for expansion, never a grant. Both endpoints must
    # independently pass the caller's authorization, otherwise anyone able to create a
    # relation could read across a boundary they were never given.
    refute hidden.knowledge.id in Enum.map(limited_result["candidates"], & &1["id"])
  end

  # Produces one `active` knowledge item and returns the account, scope, actor, and item.
  #
  # Ingest alone leaves an item awaiting approval, which retrieval correctly hides. These
  # tests are about ranking and authorization, not about the approval lifecycle, so the item
  # is transitioned to `active` through the ordinary governance engine under the pipeline
  # actor — deliberately going through the engine, not around it, so the transition writes
  # its lifecycle and audit records like any other.
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

    assert {:ok, [knowledge]} = Memory.extract_message(message["id"], account_key)

    knowledge_id = Map.fetch!(knowledge, "id")

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

  # A five-statement corpus for ranking assertions.
  #
  # One statement carries every content word of the query "Avery release checklist"; three
  # carry a strict subset; one carries none. A single-statement fixture cannot tell a ranked
  # list from an unranked one, nor a conjunctive lexical predicate from a disjunctive one,
  # because every strategy that returns anything returns the same row.
  #
  # The target is seeded first, so the recency-ordered strategies rank it last. Anything that
  # puts it at the head had to use the query.
  #
  # Each statement gets its own session: a peer restating something within one session is a
  # supersession candidate, which would retire rows this fixture needs kept side by side.
  defp seed_ranking_corpus! do
    account_key = "f7-rank"
    scope_path = "/f7/rank"

    # Shortest of the two statements naming both the person and the artifact, which keeps its
    # fixture embedding nearest the query's and makes the semantic order predictable.
    target =
      seed_active!(account_key, scope_path, "Avery maintains the release checklist.", "rank-1")

    shared_person_and_artifact =
      seed_active!(
        account_key,
        scope_path,
        "Avery approved the release notes and the changelog on Monday.",
        "rank-2"
      )

    shared_artifact =
      seed_active!(
        account_key,
        scope_path,
        "Priya updated the release checklist template.",
        "rank-3"
      )

    shared_person =
      seed_active!(
        account_key,
        scope_path,
        "Avery scheduled the quarterly retrospective.",
        "rank-4"
      )

    unrelated =
      seed_active!(account_key, scope_path, "The deployment window moved to Saturday.", "rank-5")

    # Embeddings are a rebuildable cache; rebuilding here keeps the fixture independent of
    # background job timing.
    assert {:ok, %{indexed: 5}} =
             Indexer.rebuild_scope(target.account.id, target.scope.id)

    %{
      target: target,
      shared_person_and_artifact: shared_person_and_artifact,
      shared_artifact: shared_artifact,
      shared_person: shared_person,
      unrelated: unrelated
    }
  end

  defp read_peer!(account_id, actor) do
    Cartulary.Accounts.Peer
    |> Ash.Query.filter(key == "avery")
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read_one!(actor: actor)
  end

  # The internal actor: full scope visibility and permission to touch pipeline-only actions
  # such as relation creation, entity recomputation, and lifecycle transitions. Tests that
  # assert on authorization must use a narrowed actor instead of this one.
  defp pipeline_actor(%Actor{} = actor),
    do: %{actor | role: :system, pipeline?: true, scope_ids: :all}

  # Every durable write goes through an Ash action with the account set as the tenant. The
  # tenant is what applies row-level isolation, so omitting it here would let a test write a
  # row no production code path could produce.
  defp create!(resource, action, attrs, account_id, actor) do
    resource
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_tenant(account_id)
    |> Ash.Changeset.for_create(action, attrs)
    |> Ash.create!(actor: actor)
  end

  # Forwards the projection-refresh event to the test process and returns the handler id used
  # as the message tag, so an assertion can prove the event fired with the counts an operator
  # would alert on.
  defp attach_projection_refresh_telemetry! do
    handler_id = {__MODULE__, :projection_refresh, System.unique_integer()}
    test_process = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:cartulary, :retrieval, :projection_refresh],
        fn _event, measurements, metadata, _config ->
          send(test_process, {handler_id, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    handler_id
  end

  # One-column, one-row raw query, for asserting on tables no Ash action reads back — the
  # usage ledger and counts by id after a row has been deleted out from under a resource.
  defp scalar!(sql, params) do
    %{rows: [[value]]} = Ecto.Adapters.SQL.query!(Repo, sql, params)
    value
  end
end
