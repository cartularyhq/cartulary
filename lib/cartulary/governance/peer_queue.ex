# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Governance.PeerQueue do
  @moduledoc "Peer-routed Gate A, consent, and revalidation delivery."

  alias Cartulary.Clock
  alias Cartulary.DataLayer
  alias Cartulary.Governance.Audit
  alias Cartulary.Governance.Engine
  alias Cartulary.Governance.PeerAskPreference
  alias Cartulary.Governance.PeerQuery
  alias Cartulary.Governance.PeerQueryDelivery
  alias Cartulary.Governance.ValidationItem
  alias Cartulary.Knowledge.KnowledgeItem
  alias Cartulary.Observations.Message
  alias Cartulary.Observations.Session
  alias Cartulary.Pipeline
  alias Cartulary.Pipeline.Idempotency

  require Ash.Query

  @default_deadline_days 14
  @revalidation_days 90

  def enqueue!(knowledge, validation, kind, actor) do
    PeerQuery
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_tenant(knowledge.account_id)
    |> Ash.Changeset.for_create(:enqueue, %{
      validation_item_id: validation.id,
      knowledge_id: knowledge.id,
      scope_id: knowledge.scope_id,
      peer_id: knowledge.subject_peer_id,
      kind: kind,
      statement_text: knowledge.statement,
      statement_hash: knowledge.statement_hash,
      state: "pending",
      attempts: 0,
      last_delivered_at: nil,
      answered_at: nil,
      deadline_at: DateTime.add(Clock.utc_now(), @default_deadline_days, :day)
    })
    |> Ash.create!(actor: actor)
  end

  def attach(actor, session_external_id, tool_name, topic \\ nil) do
    task =
      Task.async(fn ->
        DataLayer.with_actor(actor, fn account, current_actor ->
          do_attach(account.id, current_actor, session_external_id, tool_name, topic)
        end)
      end)

    case Task.yield(task, attach_deadline_ms()) do
      {:ok, result} ->
        result

      {:exit, _reason} ->
        nil

      nil ->
        Task.shutdown(task, :brutal_kill)
        nil
    end
  rescue
    _error -> nil
  catch
    :exit, _reason -> nil
  end

  def resolve(actor, id, verdict, shown_text \\ nil, correction_text \\ nil)

  def resolve(actor, id, verdict, shown_text, correction_text)
      when verdict in ["confirm", "reject", "unsure", "skip"] do
    DataLayer.with_actor(actor, fn account, current_actor ->
      query =
        PeerQuery
        |> Ash.Query.filter(id == ^id and peer_id == ^current_actor.peer_id)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read_one!(actor: current_actor)

      if is_nil(query),
        do: {:error, :not_found},
        else: resolve_query(query, current_actor, verdict, shown_text, correction_text)
    end)
  end

  def resolve(_actor, _id, _verdict, _shown_text, _correction_text),
    do: {:error, :invalid_verdict}

  def restrict_preferences(actor, attrs) do
    DataLayer.with_actor(actor, fn account, current_actor ->
      preference = preference!(account.id, current_actor)

      preference
      |> Ash.Changeset.for_update(:restrict, attrs)
      |> Ash.Changeset.set_tenant(account.id)
      |> Ash.update!(actor: current_actor)
    end)
  end

  defp do_attach(account_id, actor, session_external_id, tool_name, topic) do
    with {:session, %Session{} = session} <-
           {:session, session_for_peer(account_id, actor, session_external_id)},
         {:preference, preference} <- {:preference, preference!(account_id, actor)},
         {:paused, false} <- {:paused, paused?(preference)},
         {:rate, true} <-
           {:rate, inside_rate_limits?(account_id, actor, session.id, preference)},
         {:query, %PeerQuery{} = query} <- {:query, next_query(account_id, actor, topic)},
         {:delivery, false} <- {:delivery, live_delivery?(account_id, actor, query.id)} do
      delivered_at = Clock.utc_now()

      _delivery =
        PeerQueryDelivery
        |> Ash.Changeset.new()
        |> Ash.Changeset.set_tenant(account_id)
        |> Ash.Changeset.for_create(:deliver, %{
          peer_query_id: query.id,
          scope_id: query.scope_id,
          peer_id: actor.peer_id,
          session_id: session.id,
          tool_name: tool_name,
          delivered_at: delivered_at,
          verification: "pending"
        })
        |> Ash.create!(actor: actor)

      query
      |> Ash.Changeset.for_update(:update_delivery_state, %{
        state: "delivered",
        last_delivered_at: delivered_at
      })
      |> Ash.Changeset.set_tenant(account_id)
      |> Ash.update!(actor: actor)

      %{
        "id" => query.id,
        "kind" => query.kind,
        "statement" => query.statement_text,
        "asked_because" => asked_because(query.kind),
        "instruction" =>
          "Quote the statement exactly, ask whether it is still true, and call resolve_validation only if the user answers."
      }
    else
      _other -> nil
    end
  end

  defp resolve_query(query, actor, verdict, shown_text, correction_text) do
    delivery = latest_delivery!(query, actor)
    verified = transcript_verified?(query, delivery, actor)
    verification = if verified, do: "verified", else: "unverified_channel"

    conflict =
      is_binary(shown_text) && normalize(shown_text) != normalize(query.statement_text)

    delivery =
      delivery
      |> Ash.Changeset.for_update(:answer, %{
        shown_text_hash: if(is_binary(shown_text), do: Audit.content_hash(shown_text)),
        verification: verification,
        answered_at: Clock.utc_now(),
        verdict: verdict,
        conflict: conflict
      })
      |> Ash.Changeset.set_tenant(query.account_id)
      |> Ash.update!(actor: actor)

    outcome =
      case verdict do
        "skip" -> skip!(query, actor)
        "unsure" -> close_without_change!(query, actor, "unsure")
        "confirm" when verified -> confirm!(query, actor)
        "reject" when verified -> reject!(query, actor)
        _unverified -> defer_unverified!(query, actor)
      end

    Audit.append!(actor, query.account_id, %{
      scope_id: query.scope_id,
      actor_peer_id: actor.peer_id,
      category: "gate",
      action: "peer_validation.#{verdict}",
      resource_type: "peer_query",
      resource_id: query.id,
      content_hash: query.statement_hash,
      metadata: %{
        "delivery_id" => delivery.id,
        "verification" => verification,
        "correction_supplied" => is_binary(correction_text) && correction_text != "",
        "statement_evidence" => "peer_query_frozen_text"
      }
    })

    {:ok, _run} =
      Pipeline.enqueue(
        "answer_correlation",
        query.account_id,
        %{
          scope_id: query.scope_id,
          target_type: "peer_query_delivery",
          target_id: delivery.id,
          idempotency_key: Idempotency.answer_correlation(query.id, delivery.session_id),
          payload: %{
            "peer_query_id" => query.id,
            "delivery_id" => delivery.id,
            "verification" => verification
          }
        },
        actor
      )

    {:ok,
     %{
       id: query.id,
       verdict: verdict,
       verification: verification,
       effect: outcome
     }}
  end

  defp confirm!(%{kind: "consent_upward"} = query, actor) do
    validation = validation!(query, actor)

    case Engine.subject_consent(
           actor,
           query.knowledge_id,
           validation.target_scope_id,
           "grant",
           true,
           "mcp"
         ) do
      {:ok, _consent} ->
        close_query!(query, actor, "answered")
        "consent_granted"

      {:error, _reason} ->
        defer_unverified!(query, actor)
    end
  end

  defp confirm!(query, actor) do
    knowledge = knowledge!(query, actor)

    updated =
      Engine.transition!(
        knowledge,
        pipeline_actor(actor),
        %{
          state: "active",
          verification: "subject_confirmed",
          confidence: min(1.0, knowledge.confidence + 0.1),
          revalidate_after: DateTime.add(Clock.utc_now(), @revalidation_days, :day)
        },
        reason: "f4_peer_verified_confirm",
        channel: "mcp"
      )

    close_query!(query, actor, "answered")
    resolve_validation!(query, actor, "approved", "peer_confirm")

    Engine.record_decision!(
      pipeline_actor(actor),
      updated,
      query.validation_item_id,
      "gate_a",
      "keep",
      from_state: knowledge.state,
      to_state: updated.state,
      to_level: updated.target_level,
      channel: "mcp",
      verified: true,
      metadata: %{"peer_id" => actor.peer_id}
    )

    "knowledge_confirmed"
  end

  defp reject!(query, actor) do
    knowledge = knowledge!(query, actor)

    updated =
      Engine.transition!(
        knowledge,
        pipeline_actor(actor),
        %{state: "retracted", verification: "subject_rejected"},
        reason: "f4_peer_verified_reject",
        channel: "mcp"
      )

    close_query!(query, actor, "answered")
    resolve_validation!(query, actor, "rejected", "peer_reject")

    Engine.record_decision!(
      pipeline_actor(actor),
      updated,
      query.validation_item_id,
      "gate_a",
      "reject",
      from_state: knowledge.state,
      to_state: updated.state,
      to_level: updated.target_level,
      channel: "mcp",
      verified: true,
      metadata: %{"peer_id" => actor.peer_id}
    )

    "knowledge_retracted"
  end

  defp defer_unverified!(query, actor) do
    knowledge = knowledge!(query, actor)

    Engine.transition!(
      knowledge,
      pipeline_actor(actor),
      %{revalidate_after: DateTime.add(Clock.utc_now(), 7, :day)},
      reason: "f4_unverified_channel_defer",
      channel: "mcp"
    )

    query
    |> Ash.Changeset.for_update(:update_delivery_state, %{
      state: "pending",
      attempts: query.attempts + 1
    })
    |> Ash.Changeset.set_tenant(query.account_id)
    |> Ash.update!(actor: actor)

    "timer_deferred_only"
  end

  defp close_without_change!(query, actor, verdict) do
    close_query!(query, actor, "answered")
    "#{verdict}_closed"
  end

  defp skip!(query, actor) do
    attempts = query.attempts + 1

    if attempts >= max_attempts() do
      query
      |> Ash.Changeset.for_update(:update_delivery_state, %{
        state: "expired",
        attempts: attempts
      })
      |> Ash.Changeset.set_tenant(query.account_id)
      |> Ash.update!(actor: actor)

      validation = validation!(query, pipeline_actor(actor))

      validation
      |> Ash.Changeset.for_update(:decide, %{
        state: "escalated",
        escalated_at: Clock.utc_now(),
        attempt_count: validation.attempt_count + 1
      })
      |> Ash.Changeset.set_tenant(query.account_id)
      |> Ash.update!(actor: pipeline_actor(actor))

      "escalated_to_curator"
    else
      query
      |> Ash.Changeset.for_update(:update_delivery_state, %{
        state: "pending",
        attempts: attempts
      })
      |> Ash.Changeset.set_tenant(query.account_id)
      |> Ash.update!(actor: actor)

      "pending_after_skip"
    end
  end

  defp close_query!(query, actor, state) do
    query
    |> Ash.Changeset.for_update(:update_delivery_state, %{
      state: state,
      answered_at: Clock.utc_now()
    })
    |> Ash.Changeset.set_tenant(query.account_id)
    |> Ash.update!(actor: actor)
  end

  defp resolve_validation!(query, actor, state, decision) do
    validation!(query, pipeline_actor(actor))
    |> Ash.Changeset.for_update(:decide, %{
      state: state,
      decision: decision,
      decided_at: Clock.utc_now()
    })
    |> Ash.Changeset.set_tenant(query.account_id)
    |> Ash.update!(actor: pipeline_actor(actor))
  end

  defp session_for_peer(account_id, actor, external_id) do
    Session
    |> Ash.Query.filter(external_id == ^external_id and peer_id == ^actor.peer_id)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read_one!(actor: pipeline_actor(actor))
  end

  defp preference!(account_id, actor) do
    existing =
      PeerAskPreference
      |> Ash.Query.filter(peer_id == ^actor.peer_id)
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read_one!(actor: actor)

    existing ||
      PeerAskPreference
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_tenant(account_id)
      |> Ash.Changeset.for_create(:ensure, %{
        peer_id: actor.peer_id,
        max_per_session: governance_config(:max_per_session, 3),
        max_per_day: governance_config(:max_per_day, 10)
      })
      |> Ash.create!(actor: actor)
  end

  defp inside_rate_limits?(account_id, actor, session_id, preference) do
    deliveries =
      PeerQueryDelivery
      |> Ash.Query.filter(peer_id == ^actor.peer_id)
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read!(actor: actor)

    day_start = Clock.utc_now() |> DateTime.add(-1, :day)
    session_count = Enum.count(deliveries, &(&1.session_id == session_id))
    day_count = Enum.count(deliveries, &(DateTime.compare(&1.delivered_at, day_start) != :lt))

    session_count < preference.max_per_session && day_count < preference.max_per_day
  end

  defp paused?(%{paused_until: nil}), do: false
  defp paused?(preference), do: DateTime.compare(preference.paused_until, Clock.utc_now()) == :gt

  defp next_query(account_id, actor, topic) do
    PeerQuery
    |> Ash.Query.filter(peer_id == ^actor.peer_id and state in ["pending", "delivered"])
    |> Ash.Query.sort(deadline_at: :asc, inserted_at: :asc)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
    |> Enum.find(&(cooldown_elapsed?(&1) && relevant?(&1.statement_text, topic)))
  end

  defp live_delivery?(account_id, actor, query_id) do
    PeerQueryDelivery
    |> Ash.Query.filter(peer_query_id == ^query_id and is_nil(answered_at))
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
    |> Enum.any?()
  end

  defp latest_delivery!(query, actor) do
    PeerQueryDelivery
    |> Ash.Query.filter(peer_query_id == ^query.id and is_nil(answered_at))
    |> Ash.Query.sort(delivered_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.Query.set_tenant(query.account_id)
    |> Ash.read_one!(actor: actor)
    |> case do
      nil -> raise Ash.Error.Query.NotFound, resource: PeerQueryDelivery
      delivery -> delivery
    end
  end

  defp transcript_verified?(query, delivery, actor) do
    messages =
      Message
      |> Ash.Query.filter(
        session_id == ^delivery.session_id and occurred_at >= ^delivery.delivered_at
      )
      |> Ash.Query.sort(occurred_at: :asc, id: :asc)
      |> Ash.Query.set_tenant(query.account_id)
      |> Ash.read!(actor: pipeline_actor(actor))

    messages
    |> Enum.with_index()
    |> Enum.any?(fn
      {%{role: "assistant"} = message, index} ->
        shown? =
          String.contains?(normalize(message.content), normalize(query.statement_text))

        answer? =
          messages
          |> Enum.drop(index + 1)
          |> Enum.take(answer_window_turns())
          |> Enum.any?(&(&1.role == "user"))

        shown? && answer?

      _other ->
        false
    end)
  end

  defp knowledge!(query, actor) do
    KnowledgeItem
    |> Ash.Query.filter(id == ^query.knowledge_id)
    |> Ash.Query.set_tenant(query.account_id)
    |> Ash.read_one!(actor: pipeline_actor(actor))
  end

  defp validation!(query, actor) do
    ValidationItem
    |> Ash.Query.filter(id == ^query.validation_item_id)
    |> Ash.Query.set_tenant(query.account_id)
    |> Ash.read_one!(actor: actor)
  end

  defp relevant?(_statement, topic) when topic in [nil, ""], do: true

  defp relevant?(statement, topic) do
    statement_tokens = tokens(statement)
    topic_tokens = tokens(topic)
    MapSet.size(MapSet.intersection(statement_tokens, topic_tokens)) > 0
  end

  defp tokens(text) do
    text
    |> to_string()
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
    |> Enum.reject(&(String.length(&1) < 3))
    |> MapSet.new()
  end

  defp normalize(text) do
    text
    |> String.normalize(:nfkc)
    |> String.downcase()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim(~s("“”'‘’ ))
  end

  defp asked_because("confirm"), do: "This proposed memory needs your confirmation."
  defp asked_because("revalidate"), do: "This memory is due for revalidation."
  defp asked_because("consent_upward"), do: "Sharing this personal memory requires your consent."

  defp attach_deadline_ms do
    governance_config(:attach_deadline_ms, 15)
  end

  defp max_attempts, do: governance_config(:max_attempts, 2)

  defp answer_window_turns, do: governance_config(:answer_window_turns, 6)

  defp cooldown_elapsed?(%{last_delivered_at: nil}), do: true

  defp cooldown_elapsed?(query) do
    cutoff =
      DateTime.add(
        Clock.utc_now(),
        -governance_config(:attempt_cooldown_hours, 48),
        :hour
      )

    DateTime.compare(query.last_delivered_at, cutoff) != :gt
  end

  defp governance_config(key, default) do
    :cartulary
    |> Application.get_env(:governance, [])
    |> Keyword.get(key, default)
  end

  defp pipeline_actor(%Cartulary.Actor{} = actor),
    do: %{actor | role: :system, scope_ids: :all, pipeline?: true}

  defp pipeline_actor(actor),
    do: actor |> Map.put(:role, :system) |> Map.put(:pipeline?, true)
end
