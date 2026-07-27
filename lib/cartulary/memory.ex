# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Memory do
  @moduledoc """
  Compatibility facade over authoritative Ash actions.

  The public `poc-0` behavior remains frozen by F0. F1 owns durable data
  through Ash tenancy/actions and F2 owns transactional audit and AshOban
  execution. Static retrieval SQL is isolated in `Cartulary.Memory.Query`
  under the explicit F7 transition ticket.
  """

  alias Cartulary.Accounts.Peer
  alias Cartulary.Actor
  alias Cartulary.Clock
  alias Cartulary.DataLayer
  alias Cartulary.Governance.Audit
  alias Cartulary.Identity.RoleResolver
  alias Cartulary.Knowledge.Attribution
  alias Cartulary.Knowledge.KnowledgeItem
  alias Cartulary.Knowledge.LifecycleEvent
  alias Cartulary.Knowledge.Provenance
  alias Cartulary.Memory.Query
  alias Cartulary.Observability
  alias Cartulary.Observations.Message
  alias Cartulary.Observations.Session
  alias Cartulary.Observations.SessionParticipant
  alias Cartulary.Observations.SessionScope
  alias Cartulary.Pipeline.Extractor
  alias Cartulary.Pipeline.Idempotency
  alias Cartulary.Pipeline.Lock
  alias Cartulary.Topology.Scope

  require Ash.Query

  @default_limit 12

  def ingest_message(attrs, identity_actor \\ nil) do
    Observability.with_span(:memory, "cartulary.memory.ingest_message", fn ->
      attrs = attrs |> normalize_attrs() |> put_identity_actor(identity_actor)
      sync_extract? = Map.get(attrs, "sync_extract", true)
      enqueue_extract? = true

      Observability.set_attributes(:memory, %{
        "cartulary.ingest.sync_extract" => sync_extract?,
        "cartulary.ingest.enqueue_extract" => enqueue_extract?,
        "cartulary.message.role" => Map.get(attrs, "role", "user"),
        "cartulary.message.content_length" =>
          String.length(to_string(Map.get(attrs, "content", "")))
      })

      message =
        with_account(attrs, fn account, actor ->
          scope = ensure_scope!(account.id, actor, Map.fetch!(attrs, "scope_path"))

          {peer, actor} = request_peer_and_actor!(account, actor, attrs)

          session =
            ensure_session!(
              account.id,
              actor,
              scope.id,
              peer.id,
              Map.fetch!(attrs, "session_id")
            )

          ensure_session_scope!(account.id, actor, session.id, scope.id)
          ensure_session_participant!(account.id, actor, session.id, peer.id)

          message =
            create!(
              Message,
              :create,
              %{
                session_id: session.id,
                scope_id: scope.id,
                peer_id: peer.id,
                role: Map.get(attrs, "role", "user"),
                content: Map.fetch!(attrs, "content"),
                occurred_at: coerce_datetime!(Map.get(attrs, "occurred_at"))
              },
              account.id,
              actor
            )

          record_to_map(message)
        end)

      Observability.set_attribute(:memory, "cartulary.message.id", message["id"])

      if sync_extract? do
        {:ok, knowledge} =
          case identity_actor(attrs) do
            %Actor{account_id: account_id} ->
              extract_message_for_account(message["id"], account_id)

            nil ->
              extract_message(message["id"], Map.fetch!(attrs, "account_key"))
          end

        Observability.set_attribute(
          :memory,
          "cartulary.knowledge.created_count",
          length(knowledge)
        )

        {:ok, Map.put(message, "knowledge", knowledge)}
      else
        {:ok, message}
      end
    end)
  end

  def extract_message(message_id, account_key \\ nil) do
    Observability.with_span(:memory, "cartulary.memory.extract_message", fn ->
      Observability.set_attribute(:memory, "cartulary.message.id", message_id)
      account_key = account_key || Query.message_account_key!(message_id)

      knowledge =
        DataLayer.with_account_key(
          account_key,
          [role: :system, pipeline?: true],
          &extract_in_account(&1, &2, message_id)
        )

      Observability.set_attribute(:memory, "cartulary.knowledge.created_count", length(knowledge))
      {:ok, knowledge}
    end)
  end

  def extract_message_for_account(message_id, account_id) do
    Observability.with_span(:memory, "cartulary.memory.extract_message", fn ->
      Observability.set_attribute(:memory, "cartulary.message.id", message_id)

      knowledge =
        DataLayer.with_account_id(
          account_id,
          [role: :system, pipeline?: true],
          &extract_in_account(&1, &2, message_id)
        )

      Observability.set_attribute(:memory, "cartulary.knowledge.created_count", length(knowledge))
      {:ok, knowledge}
    end)
  end

  def query_knowledge(filters, identity_actor \\ nil) do
    Observability.with_span(:memory, "cartulary.memory.query_knowledge", fn ->
      filters = filters |> normalize_attrs() |> put_identity_actor(identity_actor)
      state = Map.get(filters, "state", "active")
      limit = parse_int(Map.get(filters, "limit"), @default_limit)

      rows =
        with_account(filters, fn account, actor ->
          scopes = visible_scopes(account.id, actor, Map.get(filters, "scope_path", "/poc"))
          scope_ids = Enum.map(scopes, & &1.id)
          scope_paths = Map.new(scopes, &{&1.id, &1.path})

          Observability.set_attributes(:memory, %{
            "cartulary.knowledge.state" => state,
            "cartulary.query.limit" => limit,
            "cartulary.query.scope_count" => length(scope_ids)
          })

          KnowledgeItem
          |> Ash.Query.filter(scope_id in ^scope_ids and state == ^state)
          |> Ash.Query.sort(confidence: :desc, inserted_at: :desc)
          |> Ash.Query.limit(limit)
          |> Ash.Query.set_tenant(account.id)
          |> Ash.read!(actor: actor)
          |> Enum.map(fn item ->
            item
            |> record_to_map()
            |> Map.put("scope_path", Map.fetch!(scope_paths, item.scope_id))
          end)
        end)

      Observability.set_attribute(:memory, "cartulary.query.result_count", length(rows))
      rows
    end)
  end

  def search(filters, identity_actor \\ nil) do
    Observability.with_span(:memory, "cartulary.memory.search", fn ->
      filters = filters |> normalize_attrs() |> put_identity_actor(identity_actor)
      query = Map.get(filters, "query", "")
      scope_path = Map.get(filters, "scope_path", "/poc")
      profile = parse_profile(Map.get(filters, "profile", "balanced"))
      limit = parse_int(Map.get(filters, "limit"), @default_limit)
      deadline? = Map.get(filters, "deadline", "enabled")
      started_at = System.monotonic_time(:millisecond)
      profile_config = profile_config(profile)
      strategies = Map.fetch!(profile_config, :strategies)

      {strategy_results, scope_count} =
        with_account(filters, fn account, actor ->
          scope_paths =
            account.id
            |> visible_scopes(actor, scope_path)
            |> Enum.map(& &1.path)

          results =
            Enum.map(strategies, fn strategy ->
              {strategy, Query.run_strategy(strategy, account.id, scope_paths, query, limit)}
            end)

          {results, length(scope_paths)}
        end)

      Observability.set_attributes(:memory, %{
        "cartulary.retrieval.profile" => Atom.to_string(profile),
        "cartulary.retrieval.profile_version" => Map.fetch!(profile_config, :version),
        "cartulary.retrieval.strategy_count" => length(strategies),
        "cartulary.query.limit" => limit,
        "cartulary.query.text_length" => String.length(query),
        "cartulary.query.scope_count" => scope_count
      })

      fused = fuse(strategy_results, limit)
      latency_ms = System.monotonic_time(:millisecond) - started_at

      Observability.set_attributes(:memory, %{
        "cartulary.retrieval.candidate_count" => length(fused),
        "cartulary.retrieval.latency_ms" => latency_ms
      })

      %{
        "query" => query,
        "profile" => Atom.to_string(profile),
        "profile_version" => Map.fetch!(profile_config, :version),
        "deadline" => deadline?,
        "latency_ms" => latency_ms,
        "contributed_strategies" =>
          Enum.map(strategy_results, fn {strategy, rows} -> strategy_name(strategy, rows) end),
        "dropped_strategies" => [],
        "candidates" => fused
      }
    end)
  end

  def ask(attrs, identity_actor \\ nil) do
    Observability.with_span(:memory, "cartulary.memory.ask", fn ->
      attrs = attrs |> normalize_attrs() |> put_identity_actor(identity_actor)
      question = Map.fetch!(attrs, "question")
      profile = Map.get(attrs, "profile", "thorough")

      Observability.set_attributes(:memory, %{
        "cartulary.ask.question_length" => String.length(question),
        "cartulary.retrieval.profile" => profile
      })

      retrieval =
        attrs
        |> Map.put("query", question)
        |> Map.put("profile", profile)
        |> search()

      candidates = Map.fetch!(retrieval, "candidates")

      answer =
        if model_configured?() and candidates != [] do
          model_answer(question, candidates)
        else
          fallback_answer(question, candidates)
        end

      Observability.set_attributes(:memory, %{
        "cartulary.ask.candidate_count" => length(candidates),
        "cartulary.ask.used_model" => model_configured?() and candidates != [],
        "cartulary.ask.abstained" => Map.get(answer, "abstained", false)
      })

      Map.merge(retrieval, answer)
    end)
  end

  def get_context(attrs, identity_actor \\ nil) do
    Observability.with_span(:memory, "cartulary.memory.get_context", fn ->
      attrs = attrs |> normalize_attrs() |> put_identity_actor(identity_actor)
      knowledge = query_knowledge(Map.put(attrs, "limit", Map.get(attrs, "limit", 8)))

      Observability.set_attribute(:memory, "cartulary.context.knowledge_count", length(knowledge))

      %{
        "profile_version" => "poc-0",
        "session_summary" => nil,
        "scope_cards" => [],
        "peer_profile" => [],
        "knowledge" => knowledge
      }
    end)
  end

  defp ensure_peer!(account_id, actor, key, nil),
    do: ensure_peer!(account_id, actor, key, key)

  defp ensure_peer!(account_id, actor, key, name) do
    create!(
      Peer,
      :ensure,
      %{key: key, name: name, kind: "human"},
      account_id,
      actor
    )
  end

  defp request_peer_and_actor!(account, %Actor{peer_id: peer_id} = actor, _attrs)
       when is_binary(peer_id) do
    system = Actor.for_account(account, role: :system)
    peer = read_one_by_id!(Peer, peer_id, account.id, system)

    refreshed_actor =
      RoleResolver.resolve(account, peer,
        identity_id: actor.identity_id,
        kind: actor.identity_kind,
        assurance: actor.assurance,
        api_key: %{scope_id: actor.credential_scope_id}
      )

    {peer, refreshed_actor}
  end

  defp request_peer_and_actor!(account, actor, attrs) do
    peer =
      ensure_peer!(
        account.id,
        actor,
        Map.fetch!(attrs, "peer_key"),
        Map.get(attrs, "peer_name")
      )

    {peer, actor}
  end

  defp ensure_scope!(account_id, actor, path) do
    path
    |> normalize_path()
    |> scope_segments()
    |> Enum.reduce(nil, fn {key, scope_path}, parent ->
      create!(
        Scope,
        :ensure,
        %{
          parent_id: parent && parent.id,
          key: key,
          name: key,
          path: scope_path,
          state: "active"
        },
        account_id,
        actor
      )
    end)
  end

  defp ensure_session!(account_id, actor, scope_id, peer_id, external_id) do
    create!(
      Session,
      :ensure,
      %{
        scope_id: scope_id,
        peer_id: peer_id,
        external_id: external_id,
        status: "open",
        opened_at: Clock.utc_now()
      },
      account_id,
      actor
    )
  end

  defp ensure_session_scope!(account_id, actor, session_id, scope_id) do
    create!(
      SessionScope,
      :ensure,
      %{
        session_id: session_id,
        scope_id: scope_id,
        classification: "confirmed",
        confirmed_at: Clock.utc_now()
      },
      account_id,
      actor
    )
  end

  defp ensure_session_participant!(account_id, actor, session_id, peer_id) do
    create!(
      SessionParticipant,
      :ensure,
      %{
        session_id: session_id,
        peer_id: peer_id,
        role: "participant",
        joined_at: Clock.utc_now()
      },
      account_id,
      actor
    )
  end

  defp fetch_message!(account, actor, message_id) do
    message =
      Message
      |> Ash.Query.filter(id == ^message_id)
      |> Ash.Query.set_tenant(account.id)
      |> Ash.read_one!(actor: actor)

    peer = read_one_by_id!(Peer, message.peer_id, account.id, actor)
    scope = read_one_by_id!(Scope, message.scope_id, account.id, actor)

    message
    |> record_to_map()
    |> Map.merge(%{
      "peer_key" => peer.key,
      "scope_path" => scope.path,
      "account_key" => account.key
    })
  end

  defp extract_in_account(account, actor, message_id) do
    message = fetch_message!(account, actor, message_id)
    items = Extractor.extract(message)
    Observability.set_attribute(:memory, "cartulary.extract.item_count", length(items))
    knowledge = Enum.map(items, &insert_knowledge!(account.id, actor, message, &1))
    mark_message_extracted!(account.id, actor, message_id)
    knowledge
  end

  defp insert_knowledge!(account_id, actor, message, item) do
    state =
      if item.confidence >= 0.5 and item.sensitivity in ["public", "internal"],
        do: "active",
        else: "proposed"

    statement_hash = Idempotency.content_hash(item.statement)
    Lock.acquire!(account_id, "knowledge:#{message["scope_id"]}:#{statement_hash}")

    existing =
      KnowledgeItem
      |> Ash.Query.filter(
        scope_id == ^message["scope_id"] and statement_hash == ^statement_hash and
          state in ["active", "proposed"]
      )
      |> Ash.Query.limit(1)
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read_one!(actor: actor)

    {knowledge, created?} =
      if existing do
        source_message_ids = Enum.uniq(existing.source_message_ids ++ [message["id"]])

        knowledge =
          existing
          |> Ash.Changeset.for_update(:merge_from_pipeline, %{
            source_message_ids: source_message_ids,
            confidence: max(existing.confidence, item.confidence)
          })
          |> Ash.Changeset.set_tenant(account_id)
          |> Ash.update!(actor: actor)

        {knowledge, false}
      else
        knowledge =
          create!(
            KnowledgeItem,
            :create_from_pipeline,
            %{
              scope_id: message["scope_id"],
              subject_peer_id: message["peer_id"],
              statement: item.statement,
              kind: item.kind,
              confidence: item.confidence,
              sensitivity: item.sensitivity,
              state: state,
              source_message_ids: [message["id"]],
              extracting_model: item.extracting_model,
              pipeline_version: item.pipeline_version
            },
            account_id,
            actor
          )

        {knowledge, true}
      end

    attribution = ensure_attribution!(account_id, actor, knowledge, message)

    ensure_provenance!(account_id, actor, knowledge, message, item)

    if created? do
      create!(
        LifecycleEvent,
        :record,
        %{
          knowledge_item_id: knowledge.id,
          scope_id: knowledge.scope_id,
          to_state: knowledge.state,
          reason: "poc_auto_gate",
          occurred_at: Clock.utc_now()
        },
        account_id,
        actor
      )

      Audit.append!(actor, account_id, %{
        scope_id: knowledge.scope_id,
        category: "gate",
        action: "gate.poc_auto_decided",
        resource_type: "knowledge_item",
        resource_id: knowledge.id,
        content_hash: statement_hash,
        metadata: %{"to_state" => knowledge.state}
      })

      Audit.append!(actor, account_id, %{
        scope_id: knowledge.scope_id,
        category: "lifecycle",
        action: "knowledge.created",
        resource_type: "knowledge_item",
        resource_id: knowledge.id,
        content_hash: statement_hash,
        metadata: %{"to_state" => knowledge.state}
      })

      Audit.append!(actor, account_id, %{
        scope_id: knowledge.scope_id,
        actor_peer_id: message["peer_id"],
        category: "attribution",
        action: "attribution.created",
        resource_type: "attribution",
        resource_id: attribution.id,
        content_hash: statement_hash,
        metadata: %{"knowledge_item_id" => knowledge.id, "level" => "self"}
      })
    end

    record_to_map(knowledge)
  end

  defp mark_message_extracted!(account_id, actor, message_id) do
    message = read_one_by_id!(Message, message_id, account_id, actor)

    message
    |> Ash.Changeset.for_update(:mark_extracted, %{
      extraction_completed_at: Clock.utc_now()
    })
    |> Ash.Changeset.set_tenant(account_id)
    |> Ash.update!(actor: actor)
  end

  defp ensure_provenance!(account_id, actor, knowledge, message, item) do
    existing =
      Provenance
      |> Ash.Query.filter(
        knowledge_item_id == ^knowledge.id and source_type == "message" and
          message_id == ^message["id"]
      )
      |> Ash.Query.limit(1)
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read_one!(actor: actor)

    existing ||
      create!(
        Provenance,
        :create_from_pipeline,
        %{
          knowledge_item_id: knowledge.id,
          scope_id: knowledge.scope_id,
          source_type: "message",
          message_id: message["id"],
          extracting_model: item.extracting_model,
          pipeline_version: item.pipeline_version,
          occurred_at: Clock.utc_now()
        },
        account_id,
        actor
      )
  end

  defp ensure_attribution!(account_id, actor, knowledge, message) do
    existing =
      Attribution
      |> Ash.Query.filter(
        knowledge_item_id == ^knowledge.id and target_type == "peer" and
          target_peer_id == ^message["peer_id"] and level == "self"
      )
      |> Ash.Query.limit(1)
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read_one!(actor: actor)

    existing ||
      create!(
        Attribution,
        :create_from_pipeline,
        %{
          knowledge_item_id: knowledge.id,
          scope_id: knowledge.scope_id,
          target_type: "peer",
          target_peer_id: message["peer_id"],
          level: "self"
        },
        account_id,
        actor
      )
  end

  defp visible_scopes(account_id, actor, path) do
    ancestor_paths = path |> normalize_path() |> ancestor_paths()

    Scope
    |> Ash.Query.filter(path in ^ancestor_paths)
    |> Ash.Query.sort(path: :desc)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
    |> Enum.sort_by(&String.length(&1.path), :desc)
  end

  defp read_one_by_id!(resource, id, account_id, actor) do
    resource
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read_one!(actor: actor)
  end

  defp create!(resource, action, attrs, account_id, actor) do
    resource
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_tenant(account_id)
    |> Ash.Changeset.set_context(%{cartulary_actor: actor})
    |> Ash.Changeset.for_create(action, attrs)
    |> Ash.create!(actor: actor)
  end

  defp with_account(%{"_cartulary_actor" => %Actor{} = actor}, fun),
    do: DataLayer.with_actor(actor, fun)

  defp with_account(%{"account_key" => key}, fun) when is_binary(key),
    do: DataLayer.with_account_key(key, fun)

  defp with_account(%{"account_id" => id}, fun) when is_binary(id),
    do: DataLayer.with_account_id(id, fun)

  defp with_account(_filters, _fun) do
    raise ArgumentError,
          "an authenticated identity actor or internal account adapter is required"
  end

  defp put_identity_actor(attrs, %Actor{} = actor),
    do: Map.put(attrs, "_cartulary_actor", actor)

  defp put_identity_actor(attrs, _actor), do: attrs

  defp identity_actor(%{"_cartulary_actor" => %Actor{} = actor}), do: actor
  defp identity_actor(_attrs), do: nil

  defp record_to_map(record) do
    record.__struct__
    |> Ash.Resource.Info.public_attributes()
    |> Enum.map(& &1.name)
    |> then(&Map.take(record, &1))
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp fuse(strategy_results, limit) do
    strategy_results
    |> Enum.flat_map(fn {_strategy, rows} -> rows end)
    |> Enum.group_by(& &1["id"])
    |> Enum.map(fn {_id, rows} ->
      rrf_score = Enum.reduce(rows, 0.0, fn row, acc -> acc + 1.0 / (60 + row["rank"]) end)

      rows
      |> List.first()
      |> Map.put("rrf_score", rrf_score)
      |> Map.put("strategies", Enum.map(rows, & &1["strategy"]) |> Enum.uniq())
    end)
    |> Enum.sort_by(& &1["rrf_score"], :desc)
    |> Enum.take(limit)
  end

  defp model_configured? do
    key =
      Keyword.get(Application.fetch_env!(:cartulary, :models), :api_key) ||
        System.get_env("OPENROUTER_API_KEY")

    is_binary(key) and key != ""
  end

  defp model_answer(question, candidates) do
    context =
      candidates
      |> Enum.map_join("\n", fn row -> "[#{row["id"]}] #{row["statement"]}" end)

    prompt = """
    Answer the question using only the cited Cartulary memory statements.
    Return JSON: {"answer":"...", "citations":["knowledge-id"], "abstained":false}.
    If the statements do not answer the question, return {"answer":"not known", "citations":[], "abstained":true}.

    Question: #{question}

    Memory:
    #{context}
    """

    decoded =
      Cartulary.Model.OpenRouter.chat_json!(:ask, [
        %{role: "system", content: "You are a grounded memory QA engine."},
        %{role: "user", content: prompt}
      ])

    cited_ids = candidates |> MapSet.new(& &1["id"])
    citations = decoded |> Map.get("citations", []) |> Enum.filter(&MapSet.member?(cited_ids, &1))

    %{
      "answer" => Map.get(decoded, "answer", fallback_answer(question, candidates)["answer"]),
      "citations" => citations,
      "abstained" => Map.get(decoded, "abstained", citations == [])
    }
  rescue
    _error -> fallback_answer(question, candidates)
  end

  defp fallback_answer(_question, []),
    do: %{"answer" => "not known", "citations" => [], "abstained" => true}

  defp fallback_answer(_question, candidates) do
    top = Enum.take(candidates, 4)

    %{
      "answer" => Enum.map_join(top, " ", & &1["statement"]),
      "citations" => Enum.map(top, & &1["id"]),
      "abstained" => false
    }
  end

  defp profile_config(profile) when profile in [:fast, :balanced, :thorough] do
    :cartulary
    |> Application.fetch_env!(:retrieval_profiles)
    |> Keyword.fetch!(profile)
  end

  defp profile_config(_profile), do: profile_config(:balanced)

  defp parse_profile("fast"), do: :fast
  defp parse_profile("balanced"), do: :balanced
  defp parse_profile("thorough"), do: :thorough
  defp parse_profile(:fast), do: :fast
  defp parse_profile(:balanced), do: :balanced
  defp parse_profile(:thorough), do: :thorough
  defp parse_profile(_profile), do: :balanced

  defp strategy_name(strategy, []), do: "#{strategy}:empty"
  defp strategy_name(strategy, _rows), do: Atom.to_string(strategy)

  defp normalize_attrs(attrs) when is_map(attrs) do
    Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_path(path) when is_binary(path) do
    path
    |> String.trim()
    |> case do
      "" -> "/poc"
      "/" -> "/poc"
      "/" <> _ = normalized -> normalized
      normalized -> "/" <> normalized
    end
  end

  defp normalize_path(_path), do: "/poc"

  defp scope_segments(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.reduce({[], []}, fn segment, {parts, acc} ->
      parts = parts ++ [segment]
      {parts, acc ++ [{segment, "/" <> Enum.join(parts, "/")}]}
    end)
    |> elem(1)
  end

  defp ancestor_paths(path) do
    path
    |> scope_segments()
    |> Enum.map(fn {_segment, segment_path} -> segment_path end)
  end

  defp coerce_datetime!(nil), do: Clock.utc_now()
  defp coerce_datetime!(%DateTime{} = datetime), do: datetime

  defp coerce_datetime!(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> Clock.utc_now()
    end
  end

  defp coerce_datetime!(_value), do: Clock.utc_now()

  defp parse_int(value, _default) when is_integer(value), do: value

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> default
    end
  end

  defp parse_int(_value, default), do: default
end
