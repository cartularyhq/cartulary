# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Knowledge.Changes.RecordTransition do
  @moduledoc false

  use Ash.Resource.Change

  alias Cartulary.Clock
  alias Cartulary.Governance.Audit
  alias Cartulary.Knowledge.LifecycleEvent

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, knowledge ->
      actor = get_in(changeset.context, [:private, :actor])
      from_state = changeset.data.state

      lifecycle_result =
        LifecycleEvent
        |> Ash.Changeset.new()
        |> Ash.Changeset.set_tenant(knowledge.account_id)
        |> Ash.Changeset.for_create(:record, %{
          knowledge_item_id: knowledge.id,
          scope_id: knowledge.scope_id,
          from_state: from_state,
          to_state: knowledge.state,
          reason: "governance_transition",
          occurred_at: Clock.utc_now()
        })
        |> Ash.create(actor: actor)

      with {:ok, _lifecycle} <- lifecycle_result,
           {:ok, _audit} <-
             Audit.append(actor, knowledge.account_id, %{
               scope_id: knowledge.scope_id,
               actor_peer_id: Map.get(actor, :peer_id),
               category: "lifecycle",
               action: "knowledge.transitioned",
               resource_type: "knowledge_item",
               resource_id: knowledge.id,
               content_hash: knowledge.statement_hash,
               metadata: %{
                 "from_state" => from_state,
                 "to_state" => knowledge.state
               }
             }) do
        {:ok, knowledge}
      end
    end)
  end
end
