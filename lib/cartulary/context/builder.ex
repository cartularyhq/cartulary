# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Context.Builder do
  @moduledoc "Incremental, bounded F7 projection refresh."

  alias Cartulary.Clock
  alias Cartulary.Context.Cache
  alias Cartulary.DataLayer
  alias Cartulary.Knowledge.{KnowledgeItem, Projection}
  alias Cartulary.Observations.Session
  alias Cartulary.Retrieval.Query
  alias Cartulary.Topology.Scope

  require Ash.Query

  def refresh_scope(account_id, scope_id) do
    DataLayer.with_account_id(
      account_id,
      [role: :system, pipeline?: true],
      fn _account, actor ->
        scope = read_one!(Scope, scope_id, account_id, actor)

        knowledge =
          KnowledgeItem
          |> Ash.Query.filter(
            scope_id == ^scope_id and state in ["active", "provisional"] and is_nil(deleted_at)
          )
          |> Ash.Query.sort(confidence: :desc, updated_at: :desc)
          |> Ash.Query.set_tenant(account_id)
          |> Ash.read!(actor: actor)

        knowledge = dream_rank(knowledge, scope, account_id, actor)

        scope_projection =
          upsert_projection!(
            account_id,
            actor,
            %{
              cache_key: "scope:#{scope_id}",
              scope_id: scope_id,
              kind: "scope_card",
              content: %{
                "scope_id" => scope_id,
                "path" => scope.path,
                "name" => scope.name,
                "knowledge" => Enum.map(knowledge, &knowledge_map/1)
              },
              source_ids: Enum.map(knowledge, & &1.id)
            }
          )

        peer_projections =
          knowledge
          |> Enum.filter(&is_binary(&1.subject_peer_id))
          |> Enum.group_by(& &1.subject_peer_id)
          |> Enum.map(fn {peer_id, items} ->
            upsert_projection!(
              account_id,
              actor,
              %{
                cache_key: "peer:#{scope_id}:#{peer_id}",
                scope_id: scope_id,
                peer_id: peer_id,
                kind: "peer_profile",
                content: %{"knowledge" => Enum.map(items, &knowledge_map/1)},
                source_ids: Enum.map(items, & &1.id)
              }
            )
          end)

        session_projections =
          Session
          |> Ash.Query.filter(scope_id == ^scope_id)
          |> Ash.Query.set_tenant(account_id)
          |> Ash.read!(actor: actor)
          |> Enum.map(fn session ->
            upsert_projection!(
              account_id,
              actor,
              %{
                cache_key: "session:#{scope_id}:#{session.id}",
                scope_id: scope_id,
                peer_id: session.peer_id,
                session_id: session.id,
                kind: "session_summary",
                content: %{
                  "session_id" => session.id,
                  "status" => session.status,
                  "knowledge" => Enum.map(knowledge, &knowledge_map/1)
                },
                source_ids: Enum.map(knowledge, & &1.id)
              }
            )
          end)

        Cache.invalidate_scope(account_id, scope_id)

        {:ok,
         %{
           scope_card: scope_projection.id,
           peer_profiles: length(peer_projections),
           session_summaries: length(session_projections)
         }}
      end
    )
  end

  def mark_dirty(account_id, actor, scope_id) do
    Projection
    |> Ash.Query.filter(scope_id == ^scope_id)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
    |> Enum.each(fn projection ->
      projection
      |> Ash.Changeset.for_update(:refresh_from_pipeline, %{dirty: true})
      |> Ash.Changeset.set_tenant(account_id)
      |> Ash.update!(actor: actor, authorize?: false)
    end)

    Cache.invalidate_scope(account_id, scope_id)
  end

  defp upsert_projection!(account_id, actor, attrs) do
    existing =
      Projection
      |> Ash.Query.filter(cache_key == ^attrs.cache_key)
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read_one!(actor: actor)

    compaction_every = retrieval_config(:projection_compaction_every)
    compact? = is_nil(existing) or existing.delta_count + 1 >= compaction_every

    {content, source_ids, delta_count} =
      if existing && not compact? do
        {
          merge_content(existing.content, attrs.content, attrs.source_ids),
          attrs.source_ids,
          existing.delta_count + 1
        }
      else
        {attrs.content, attrs.source_ids, 0}
      end

    create_attrs =
      attrs
      |> Map.merge(%{
        version: (existing && existing.version + 1) || 1,
        content: content,
        source_ids: source_ids,
        dirty: false,
        watermark: Clock.utc_now(),
        delta_count: delta_count
      })

    Projection
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_tenant(account_id)
    |> Ash.Changeset.for_create(:upsert_from_pipeline, create_attrs)
    |> Ash.create!(actor: actor, authorize?: false)
  end

  defp merge_content(old, new, current_source_ids) do
    current_source_ids = MapSet.new(current_source_ids)

    Map.merge(old, new, fn
      "knowledge", old_items, new_items ->
        (Enum.filter(old_items, &MapSet.member?(current_source_ids, &1["id"])) ++ new_items)
        |> Enum.uniq_by(& &1["id"])
        |> Enum.take(100)

      _key, _old_value, new_value ->
        new_value
    end)
  end

  defp knowledge_map(item) do
    %{
      "id" => item.id,
      "scope_id" => item.scope_id,
      "statement" => item.statement,
      "kind" => item.kind,
      "confidence" => item.confidence,
      "sensitivity" => item.sensitivity,
      "state" => item.state,
      "source_message_ids" => item.source_message_ids,
      "extracting_model" => item.extracting_model,
      "pipeline_version" => item.pipeline_version
    }
  end

  defp dream_rank([], _scope, _account_id, _actor), do: []

  defp dream_rank(knowledge, scope, account_id, actor) do
    query = %Query{
      account_id: account_id,
      actor: actor,
      scope_ids: [scope.id],
      text: "#{scope.name} context",
      target: :knowledge,
      max_candidates: max(length(knowledge), 1)
    }

    ranked_ids =
      query
      |> Cartulary.Retrieval.retrieve(:thorough,
        deadline?: false,
        concurrent?: false,
        internal?: true
      )
      |> Map.fetch!(:candidates)
      |> Enum.map(& &1["id"])

    by_id = Map.new(knowledge, &{&1.id, &1})
    ranked = Enum.map(ranked_ids, &Map.get(by_id, &1)) |> Enum.reject(&is_nil/1)
    ranked ++ Enum.reject(knowledge, &(&1.id in ranked_ids))
  end

  defp read_one!(resource, id, account_id, actor) do
    resource
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read_one!(actor: actor)
  end

  defp retrieval_config(key) do
    :cartulary
    |> Application.fetch_env!(:retrieval_profiles)
    |> Keyword.fetch!(key)
  end
end
