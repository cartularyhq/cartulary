# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Context.Builder do
  @moduledoc """
  Rebuilds the context projections for one scope: its scope card, peer profile slices, and
  session summaries.

  This is the write side of the projection caches that `Cartulary.Context` reads. It runs in the
  background — from the queued `projection_refresh` lane, from the rebuild an archive import
  enqueues, after an erasure, and (for `mark_dirty/3`) whenever a governance decision changes a
  statement's lifecycle. Because it is off the per-request path, it is allowed to do the
  expensive work that context assembly may not: it ranks statements with the `:thorough`
  retrieval profile, which as shipped includes a model-backed rerank.

  ## Everything here is derived, nothing here is truth

  Every row written by this module is reconstructible from governed statements. Dropping the
  projection table costs latency, never information. That is why these writes run as the
  internal pipeline actor with policy checks disabled — the Account tenant is still pinned on
  every changeset — and why running a refresh twice is harmless.

  ## Freshness protocol

  Two operations, one contract:

  * `refresh_scope/2` rebuilds content and clears `dirty`.
  * `mark_dirty/3` flips `dirty` without touching content, and must be called in the same
    transaction as the lifecycle change that invalidated the projection. If the flag were set
    after the state change committed, there would be a window in which a rejected, redacted, or
    erased statement is still served from a card that looks clean.

  Both end by evicting the node-local cache entries for the scope and broadcasting the eviction,
  because a stale in-memory copy outlives a database update otherwise.

  ## Bounded growth

  Refreshes merge incrementally so a busy scope does not re-serialize its whole card on every
  statement, but a merge can only drift so far from the truth. After a configured number of
  merges the next refresh discards the merged content and rewrites it from the current
  statements. Merged knowledge lists are additionally capped, so an unlucky sequence of merges
  cannot grow a projection without limit.
  """

  alias Cartulary.Clock
  alias Cartulary.Context.Cache
  alias Cartulary.DataLayer
  alias Cartulary.Knowledge.{KnowledgeItem, Projection}
  alias Cartulary.Observations.Session
  alias Cartulary.Retrieval.Query
  alias Cartulary.Topology.Scope

  require Ash.Query

  @doc """
  Rebuilds every projection belonging to one scope and clears their dirty flags.

  Runs as the internal pipeline actor inside a single Account-scoped transaction, so either all
  of a scope's projections advance together or none of them do. Statements in `active` and
  `provisional` state are included; soft-deleted rows are not.

  Returns `{:ok, map}` with the scope card's id and the number of peer profile and session
  summary projections written. Raises if the transaction fails or an underlying Ash call fails.

  Safe to run repeatedly: every projection is upserted on its cache key, so a replay merges into
  or fully rewrites the existing row rather than adding another one, and the same statements
  produce the same content.
  """
  def refresh_scope(account_id, scope_id) do
    DataLayer.with_account_id(
      account_id,
      [role: :system, pipeline?: true],
      fn _account, actor ->
        scope = read_one!(Scope, scope_id, account_id, actor)

        # Confidence-first ordering is the fallback ranking. When the retrieval-based ranking
        # below contributes nothing (empty corpus, no candidates), this order is what the card
        # ships with.
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

        # A peer profile slice holds the statements this scope knows *about* that peer — it is
        # grouped by subject, not by who said it. Someone else's observation about a peer
        # belongs in that peer's slice; the peer's own remark about a third party does not.
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

        # One summary per session in the scope, each carrying the same scope-wide ranked
        # knowledge plus the session's own identity and status. The summary is a warm start for
        # resuming a conversation, so it is refreshed with the scope rather than derived from
        # the session's message history.
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

        # Every node keeps its own in-memory copy of these projections, so the rebuild is not
        # finished until those copies are evicted cluster-wide.
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

  @doc """
  Marks every projection in a scope as unusable and evicts the in-memory copies.

  This is the cheap half of the freshness protocol: content is left alone and only the flag
  flips, because the read path refuses dirty rows outright and falls back to live retrieval.
  Call it from inside the transaction that changed a statement's lifecycle state, so the flag
  and the state change commit together rather than leaving a rejected, redacted, or erased
  statement behind a card that still looks clean. `actor` must be an internal pipeline actor;
  marking a cache dirty is a pipeline-owned write even when the trigger was a curator's
  decision.

  Returns `:ok`. Raises if a read or update fails.
  """
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

  # Writes one projection, choosing between an incremental merge and a full rewrite.
  #
  # A full rewrite happens when the projection is new or when the merge budget is exhausted;
  # otherwise the previous content is merged with the new content and the delta counter
  # advances. `version` increments on every write so a reader can tell two generations apart,
  # `watermark` records when the content was last computed, and `dirty` is cleared because the
  # row now reflects the statements just read.
  #
  # Authorization is disabled deliberately: these are derived caches written by the internal
  # pipeline from rows it has already read in this transaction. The Account boundary still
  # holds, because the tenant is pinned on every changeset.
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

  # Incremental merge of a projection's content.
  #
  # The knowledge list is the only key merged rather than replaced. Old entries survive only if
  # their statement id is still among the current source ids, which is how a statement that was
  # rejected, superseded, or erased leaves a merged card without waiting for a full rebuild.
  # Deduplication keeps the first occurrence, so an id present in both lists keeps the entry
  # already rendered; genuinely new ids are appended after it. Periodic full compaction is what
  # eventually corrects any drift this introduces.
  #
  # The cap is 100 statement entries per merged projection. It bounds how large a delta-merged
  # card can grow between compactions; a card is a warm start, and a caller that needs more than
  # this should be searching, not reading a projection.
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

  # The projected shape of one statement. This is an allowlist, not a serialization of the row:
  # a field that is not named here never reaches a projection, and therefore never reaches a
  # context payload. Embedding vectors, entity links, and internal bookkeeping stay out.
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

  # Reorders a scope's statements by relevance to the scope itself, using the most thorough
  # retrieval profile. This is the one place in the context subsystem where a model may be
  # invoked, because it runs in the background rebuild rather than on an agent's turn.
  #
  # Two options are non-obvious and load-bearing:
  #
  #   * `deadline?: false` — background quality beats latency here. A partial ranking would be
  #     baked into a cache that many later requests read, so the strategies are allowed to
  #     finish instead of being dropped at a deadline.
  #   * `concurrent?: false` — the whole refresh runs inside one Account-scoped transaction,
  #     which owns a single database connection. Fanning strategies out to other processes
  #     would take them outside that transaction, so they run serially here.
  #
  # Statements the ranker did not return are appended in their original confidence order, so
  # ranking can only reorder the card, never silently drop a statement from it.
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

  # `fetch!` on both levels on purpose: a missing retrieval configuration key is a deployment
  # error. Defaulting it silently would change the compaction cadence, and therefore how far a
  # projection may drift from the statements, without anyone noticing.
  defp retrieval_config(key) do
    :cartulary
    |> Application.fetch_env!(:retrieval_profiles)
    |> Keyword.fetch!(key)
  end
end
