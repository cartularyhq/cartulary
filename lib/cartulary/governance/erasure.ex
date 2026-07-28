# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Governance.Erasure do
  @moduledoc """
  Account-scoped proportionate and strict peer erasure.

  Content-bearing records are removed through Ash destroy/update actions.
  Hash/id-only audit evidence survives, while projections and entity resolution
  are marked or recomputed from the surviving system of record.
  """

  alias Cartulary.Accounts.ApiKey
  alias Cartulary.Accounts.ExternalIdentity
  alias Cartulary.Accounts.Peer
  alias Cartulary.Clock
  alias Cartulary.DataLayer
  alias Cartulary.Governance.Audit
  alias Cartulary.Governance.ErasureRequest
  alias Cartulary.Governance.PeerQuery
  alias Cartulary.Governance.PeerQueryDelivery
  alias Cartulary.Knowledge.Attribution
  alias Cartulary.Knowledge.Entity
  alias Cartulary.Knowledge.EntityMention
  alias Cartulary.Knowledge.KnowledgeItem
  alias Cartulary.Knowledge.Projection
  alias Cartulary.Knowledge.Provenance
  alias Cartulary.Observations.Message
  alias Cartulary.Observations.Session
  alias Cartulary.Observations.SessionParticipant
  alias Cartulary.Observations.SessionScope
  alias Cartulary.Topology.RoleGrant

  require Ash.Query

  def request(actor, peer_id, mode) when mode in ["proportionate", "strict"] do
    allowed? =
      actor.peer_id == peer_id ||
        (actor.identity_kind == :password && actor.role == :account_admin)

    unless allowed? do
      raise Ash.Error.Forbidden, errors: []
    end

    DataLayer.with_actor(actor, fn account, current_actor ->
      request =
        ErasureRequest
        |> Ash.Changeset.new()
        |> Ash.Changeset.set_tenant(account.id)
        |> Ash.Changeset.for_create(:request, %{
          peer_id: peer_id,
          mode: mode,
          requested_by_peer_id: current_actor.peer_id,
          state: "pending",
          requested_at: Clock.utc_now()
        })
        |> Ash.create!(actor: current_actor)

      execute!(request, pipeline_actor(current_actor))
    end)
  end

  def request(_actor, _peer_id, _mode), do: raise(ArgumentError, "invalid erasure mode")

  def execute!(request, actor) do
    account_id = request.account_id

    peer =
      Peer
      |> Ash.Query.filter(id == ^request.peer_id)
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read_one!(actor: actor)

    if is_nil(peer), do: raise(Ash.Error.Query.NotFound, resource: Peer)

    messages =
      Message
      |> Ash.Query.filter(peer_id == ^request.peer_id)
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read!(actor: actor)

    message_ids = MapSet.new(messages, & &1.id)

    all_knowledge =
      KnowledgeItem
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read!(actor: actor)

    subject_knowledge = Enum.filter(all_knowledge, &(&1.subject_peer_id == request.peer_id))

    sourced_knowledge =
      Enum.filter(all_knowledge, fn knowledge ->
        Enum.any?(knowledge.source_message_ids, &MapSet.member?(message_ids, &1))
      end)

    strict_extra =
      if request.mode == "strict" do
        sourced_knowledge -- subject_knowledge
      else
        []
      end

    delete_knowledge = Enum.uniq_by(subject_knowledge ++ strict_extra, & &1.id)
    delete_ids = MapSet.new(delete_knowledge, & &1.id)

    recompute_projections!(account_id, actor, request.peer_id, delete_ids)
    recompute_entities!(account_id, actor, delete_ids)
    erase_peer_queries!(account_id, actor, request.peer_id)
    erase_knowledge_rows!(account_id, actor, delete_knowledge)

    retained_sourced =
      sourced_knowledge
      |> Enum.reject(&MapSet.member?(delete_ids, &1.id))
      |> Enum.map(&scrub_source!(&1, actor, message_ids))

    Enum.each(messages, &destroy!(&1, :erase, actor))
    erase_sessions_and_identity!(account_id, actor, request.peer_id)

    counts = %{
      "messages" => length(messages),
      "knowledge_deleted" => length(delete_knowledge),
      "knowledge_source_scrubbed" => length(retained_sourced),
      "mode" => request.mode
    }

    completed = complete!(request, actor, counts)

    Audit.append!(actor, account_id, %{
      actor_peer_id: request.requested_by_peer_id,
      category: "deletion",
      action: "peer.erased",
      resource_type: "peer",
      resource_id: request.peer_id,
      metadata: counts
    })

    destroy!(peer, :erase, actor)
    completed
  end

  defp scrub_source!(knowledge, actor, message_ids) do
    surviving_ids =
      Enum.reject(knowledge.source_message_ids, &MapSet.member?(message_ids, &1))

    provenances =
      Provenance
      |> Ash.Query.filter(knowledge_item_id == ^knowledge.id)
      |> Ash.Query.set_tenant(knowledge.account_id)
      |> Ash.read!(actor: actor)

    provenances
    |> Enum.filter(&MapSet.member?(message_ids, &1.message_id))
    |> Enum.each(&destroy!(&1, :erase, actor))

    if surviving_ids == [] do
      Cartulary.Governance.Engine.transition!(
        knowledge,
        actor,
        %{
          state: "retracted",
          verification: "sole_source_erased",
          source_message_ids: []
        },
        reason: "f4_proportionate_erasure_sole_source",
        channel: "erasure"
      )
    else
      knowledge
      |> Ash.Changeset.for_update(:merge_from_pipeline, %{source_message_ids: surviving_ids})
      |> Ash.Changeset.set_tenant(knowledge.account_id)
      |> Ash.update!(actor: actor)
    end
  end

  @doc false
  def erase_knowledge_rows!(account_id, actor, knowledge_rows) do
    ids = Enum.map(knowledge_rows, & &1.id)

    EntityMention
    |> Ash.Query.filter(knowledge_item_id in ^ids)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
    |> Enum.each(&destroy!(&1, :erase, actor))

    Attribution
    |> Ash.Query.filter(knowledge_item_id in ^ids)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
    |> Enum.each(&destroy!(&1, :erase, actor))

    Provenance
    |> Ash.Query.filter(knowledge_item_id in ^ids)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
    |> Enum.each(&destroy!(&1, :erase, actor))

    Enum.each(knowledge_rows, &destroy!(&1, :erase, actor))
  end

  defp erase_peer_queries!(account_id, actor, peer_id) do
    queries =
      PeerQuery
      |> Ash.Query.filter(peer_id == ^peer_id)
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read!(actor: actor)

    query_ids = Enum.map(queries, & &1.id)

    PeerQueryDelivery
    |> Ash.Query.filter(peer_query_id in ^query_ids)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
    |> Enum.each(&destroy!(&1, :erase, actor))

    Enum.each(queries, &destroy!(&1, :erase, actor))
  end

  defp recompute_projections!(account_id, actor, peer_id, deleted_ids) do
    Projection
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
    |> Enum.filter(fn projection ->
      projection.peer_id == peer_id ||
        Enum.any?(projection.source_ids, &MapSet.member?(deleted_ids, &1))
    end)
    |> Enum.each(fn projection ->
      projection
      |> Ash.Changeset.for_update(:refresh_from_pipeline, %{dirty: true})
      |> Ash.Changeset.set_tenant(account_id)
      |> Ash.update!(actor: actor)
    end)
  end

  defp recompute_entities!(account_id, actor, deleted_ids) do
    Entity
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
    |> Enum.each(fn entity ->
      surviving = Enum.reject(entity.derived_from, &MapSet.member?(deleted_ids, &1))

      cond do
        surviving == entity.derived_from ->
          :ok

        surviving == [] ->
          destroy!(entity, :erase, actor)

        true ->
          entity
          |> Ash.Changeset.for_update(:recompute_from_pipeline, %{derived_from: surviving})
          |> Ash.Changeset.set_tenant(account_id)
          |> Ash.update!(actor: actor)
      end
    end)
  end

  defp erase_sessions_and_identity!(account_id, actor, peer_id) do
    sessions =
      Session
      |> Ash.Query.filter(peer_id == ^peer_id)
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read!(actor: actor)

    session_ids = Enum.map(sessions, & &1.id)

    SessionParticipant
    |> Ash.Query.filter(peer_id == ^peer_id or session_id in ^session_ids)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
    |> Enum.each(&destroy!(&1, :erase, actor))

    SessionScope
    |> Ash.Query.filter(session_id in ^session_ids)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
    |> Enum.each(&destroy!(&1, :erase, actor))

    Enum.each(sessions, &destroy!(&1, :erase, actor))

    ApiKey
    |> Ash.Query.filter(peer_id == ^peer_id)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
    |> Enum.each(&destroy!(&1, :destroy, actor))

    ExternalIdentity
    |> Ash.Query.filter(peer_id == ^peer_id)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
    |> Enum.each(&destroy!(&1, :erase, actor))

    RoleGrant
    |> Ash.Query.filter(peer_id == ^peer_id)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
    |> Enum.each(&destroy!(&1, :erase, actor))
  end

  defp complete!(request, actor, counts) do
    request
    |> Ash.Changeset.for_update(:complete, %{
      state: "completed",
      affected_counts: counts,
      completed_at: Clock.utc_now()
    })
    |> Ash.Changeset.set_tenant(request.account_id)
    |> Ash.update!(actor: actor)
  end

  defp destroy!(record, action, actor) do
    record
    |> Ash.Changeset.for_destroy(action)
    |> Ash.Changeset.set_tenant(record.account_id)
    |> Ash.destroy!(actor: actor)
  end

  defp pipeline_actor(%Cartulary.Actor{} = actor),
    do: %{actor | role: :system, scope_ids: :all, pipeline?: true}

  defp pipeline_actor(actor),
    do: actor |> Map.put(:role, :system) |> Map.put(:pipeline?, true)
end
