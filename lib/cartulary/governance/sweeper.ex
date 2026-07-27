# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Governance.Sweeper do
  @moduledoc "Dream-time lifecycle sweeps for revalidation, expiry, queue aging, and decay."

  alias Cartulary.Clock
  alias Cartulary.DataLayer
  alias Cartulary.Governance.Engine
  alias Cartulary.Governance.PeerQuery
  alias Cartulary.Governance.PeerQueue
  alias Cartulary.Governance.ValidationItem
  alias Cartulary.Knowledge.KnowledgeItem

  require Ash.Query

  def run(account_id, kind) when kind in ["revalidation", "expiry", "dream_time"] do
    DataLayer.with_account_id(account_id, [role: :system, pipeline?: true], fn account, actor ->
      counts =
        case kind do
          "revalidation" -> %{revalidation: revalidate!(account.id, actor)}
          "expiry" -> %{expiry: expire!(account.id, actor)}
          "dream_time" -> full_sweep(account.id, actor)
        end

      {:ok, counts}
    end)
  end

  defp full_sweep(account_id, actor) do
    %{
      revalidation: revalidate!(account_id, actor),
      expiry: expire!(account_id, actor),
      aged: age_queue!(account_id, actor),
      decayed: decay_queries!(account_id, actor)
    }
  end

  defp revalidate!(account_id, actor) do
    due_knowledge(account_id, actor, :revalidate_after)
    |> Enum.map(fn knowledge ->
      updated =
        Engine.transition!(
          knowledge,
          actor,
          %{state: "needs_revalidation", verification: "stale"},
          reason: "f4_revalidation_due",
          channel: "dream_time"
        )

      validation =
        ValidationItem
        |> Ash.Changeset.new()
        |> Ash.Changeset.set_tenant(account_id)
        |> Ash.Changeset.for_create(:enqueue, %{
          knowledge_id: updated.id,
          scope_id: updated.scope_id,
          subject_peer_id: updated.subject_peer_id,
          target_level: updated.target_level,
          kind: "revalidation",
          state: "pending",
          statement_hash: updated.statement_hash,
          confidence: updated.confidence,
          sensitivity: updated.sensitivity,
          due_at: DateTime.add(Clock.utc_now(), 14, :day)
        })
        |> Ash.create!(actor: actor)

      if is_binary(updated.subject_peer_id) do
        PeerQueue.enqueue!(updated, validation, "revalidate", actor)
      end

      updated
    end)
    |> length()
  end

  defp expire!(account_id, actor) do
    due_knowledge(account_id, actor, :expires_at)
    |> Enum.map(
      &Engine.transition!(
        &1,
        actor,
        %{state: "expired", verification: "expired"},
        reason: "f4_expiry_due",
        channel: "dream_time"
      )
    )
    |> length()
  end

  defp age_queue!(account_id, actor) do
    now = Clock.utc_now()

    ValidationItem
    |> Ash.Query.filter(
      due_at <= ^now and state in ["pending", "deferred", "awaiting_consent", "escalated"]
    )
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
    |> Enum.map(fn validation ->
      if validation.state == "escalated" || validation.attempt_count > 0 do
        knowledge = knowledge!(account_id, actor, validation.knowledge_id)

        Engine.transition!(
          knowledge,
          actor,
          %{state: "rejected", verification: "auto_rejected_stale"},
          reason: "f4_pending_auto_reject",
          channel: "dream_time"
        )

        validation
        |> Ash.Changeset.for_update(:decide, %{
          state: "rejected",
          decision: "auto_reject",
          attempt_count: validation.attempt_count + 1,
          decided_at: now
        })
        |> Ash.Changeset.set_tenant(account_id)
        |> Ash.update!(actor: actor)
      else
        validation
        |> Ash.Changeset.for_update(:decide, %{
          state: "escalated",
          attempt_count: 1,
          escalated_at: now,
          due_at: DateTime.add(now, 24, :hour)
        })
        |> Ash.Changeset.set_tenant(account_id)
        |> Ash.update!(actor: actor)
      end
    end)
    |> length()
  end

  defp decay_queries!(account_id, actor) do
    now = Clock.utc_now()

    PeerQuery
    |> Ash.Query.filter(deadline_at <= ^now and state in ["pending", "delivered"])
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
    |> Enum.map(fn query ->
      knowledge = knowledge!(account_id, actor, query.knowledge_id)

      Engine.transition!(
        knowledge,
        actor,
        %{
          state: "stale",
          verification: "revalidation_missed",
          confidence: max(0.0, knowledge.confidence - 0.15)
        },
        reason: "f4_revalidation_confidence_decay",
        channel: "dream_time"
      )

      query
      |> Ash.Changeset.for_update(:update_delivery_state, %{
        state: "expired",
        attempts: query.attempts + 1
      })
      |> Ash.Changeset.set_tenant(account_id)
      |> Ash.update!(actor: actor)
    end)
    |> length()
  end

  defp due_knowledge(account_id, actor, attribute) do
    now = Clock.utc_now()

    query =
      case attribute do
        :revalidate_after ->
          Ash.Query.filter(
            KnowledgeItem,
            revalidate_after <= ^now and state == "active"
          )

        :expires_at ->
          Ash.Query.filter(
            KnowledgeItem,
            expires_at <= ^now and state not in ["expired", "rejected", "retracted", "redacted"]
          )
      end

    query
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
  end

  defp knowledge!(account_id, actor, id) do
    KnowledgeItem
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read_one!(actor: actor)
  end
end
