# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Knowledge.Changes.RecordTransition do
  @moduledoc """
  Ash change that turns a knowledge state change into an evidence-carrying transaction.

  Attached to the statement's `transition` action, it appends two records after the update
  succeeds and before the surrounding transaction commits:

  1. a `LifecycleEvent` naming the state left, the state entered, the caller's reason, and the
     time of the transition; and
  2. a hash-chained governance audit entry in the `lifecycle` category.

  Both live inside the caller's transaction. If either write fails, the `with` returns the error
  and the state change is rolled back with them, so a statement can never quietly change state
  without leaving a trail. That coupling is the whole point of the change; splitting it into a
  background job would reintroduce exactly the gap it closes.

  ## Content safety

  The audit entry carries the statement's hash, not its text. The metadata is limited to the two
  states, the reason code, and the channel that drove the decision. Never add statement text,
  peer answers, or prompt content to this map — the audit chain is designed to be readable by
  operators who are not entitled to the underlying knowledge.

  ## Reading the pre-update state

  `from_state` comes from the changeset's loaded record, which is why the action declares itself
  non-atomic. Making `transition` atomic would remove the loaded row and silently record a wrong
  or nil origin state.
  """

  use Ash.Resource.Change

  alias Cartulary.Clock
  alias Cartulary.Governance.Audit
  alias Cartulary.Knowledge.LifecycleEvent

  @doc """
  Registers the after-action hook that writes the lifecycle event and the audit entry.

  Returns the changeset. At run time the hook returns `{:ok, knowledge}` on success, or the
  first `{:error, reason}` from the lifecycle or audit write, which aborts the transaction.
  """
  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, knowledge ->
      actor = get_in(changeset.context, [:private, :actor])

      # The pre-update row, captured before Ash applied the new attributes.
      from_state = changeset.data.state
      reason = Ash.Changeset.get_argument(changeset, :reason)
      channel = Ash.Changeset.get_argument(changeset, :channel)

      lifecycle_result =
        LifecycleEvent
        |> Ash.Changeset.new()
        |> Ash.Changeset.set_tenant(knowledge.account_id)
        |> Ash.Changeset.for_create(:record, %{
          knowledge_item_id: knowledge.id,
          scope_id: knowledge.scope_id,
          from_state: from_state,
          to_state: knowledge.state,
          reason: reason,
          occurred_at: Clock.utc_now()
        })
        |> Ash.create(actor: actor)

      # Any error here propagates out of the after-action hook and rolls back the state change
      # together with whichever of the two evidence writes already succeeded.
      with {:ok, _lifecycle} <- lifecycle_result,
           {:ok, _audit} <-
             Audit.append(actor, knowledge.account_id, %{
               scope_id: knowledge.scope_id,
               actor_peer_id: Map.get(actor, :peer_id),
               category: "lifecycle",
               action: "knowledge.transitioned",
               resource_type: "knowledge_item",
               resource_id: knowledge.id,
               # The hash stands in for the statement so the audit chain holds no content.
               content_hash: knowledge.statement_hash,
               metadata: %{
                 "from_state" => from_state,
                 "to_state" => knowledge.state,
                 "reason" => reason,
                 "channel" => channel
               }
             }) do
        {:ok, knowledge}
      end
    end)
  end
end
