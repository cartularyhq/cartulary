# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Governance.Engine do
  @moduledoc """
  Transactional Gate A/B operation layer.

  New reasoned knowledge enters here as a proposal. The engine evaluates a
  versioned matrix cell, creates the durable validation/peer queues when human
  judgment is required, and records both the immutable decision history and
  hash-chained audit evidence for every gate and lifecycle mutation.
  """

  alias Cartulary.Clock
  alias Cartulary.DataLayer
  alias Cartulary.Governance.Audit
  alias Cartulary.Governance.Consent
  alias Cartulary.Governance.GateDecision
  alias Cartulary.Governance.GateRule
  alias Cartulary.Governance.PeerQueue
  alias Cartulary.Governance.ValidationItem
  alias Cartulary.Knowledge.KnowledgeItem
  alias Cartulary.Knowledge.KnowledgeRelation
  alias Cartulary.Knowledge.Provenance
  alias Cartulary.Pipeline
  alias Cartulary.Pipeline.Idempotency
  alias Cartulary.Pipeline.Lock
  alias Cartulary.Topology.Scope

  require Ash.Query

  @human_actions ~w(approve edit reject merge defer)

  def evaluate_proposal(knowledge, actor, opts \\ []) do
    target_level = Keyword.get(opts, :target_level, knowledge.target_level || "peer")
    target_scope_id = Keyword.get(opts, :target_scope_id)
    rule = matching_rule(knowledge, target_level, actor)
    due_at = DateTime.add(Clock.utc_now(), rule.pending_max_age_hours, :hour)

    case proposal_outcome(knowledge, rule, target_level) do
      :reject ->
        knowledge
        |> transition!(actor, %{state: "rejected", verification: "auto_rejected"},
          reason: "f4_gate_a_auto_reject",
          channel: "pipeline"
        )
        |> tap(fn updated ->
          record_decision!(
            actor,
            updated,
            nil,
            "gate_a",
            "reject",
            from_state: knowledge.state,
            to_state: updated.state,
            to_level: target_level,
            channel: "pipeline",
            verified: true,
            metadata: %{"rule_id" => rule_id(rule)}
          )
        end)

      :accept ->
        knowledge
        |> transition!(
          actor,
          %{
            state: "active",
            target_level: target_level,
            verification: "auto_verified",
            held_scope_id: nil,
            revalidate_after: revalidate_at(rule)
          },
          reason: "f4_gate_a_b_auto_accept",
          channel: "pipeline"
        )
        |> tap(fn updated ->
          record_decision!(
            actor,
            updated,
            nil,
            "gate_a",
            "keep",
            from_state: knowledge.state,
            to_state: updated.state,
            to_level: target_level,
            channel: "pipeline",
            verified: true,
            metadata: %{"rule_id" => rule_id(rule)}
          )

          record_decision!(
            actor,
            updated,
            nil,
            "gate_b",
            "place",
            from_state: knowledge.state,
            to_state: updated.state,
            to_level: target_level,
            channel: "pipeline",
            verified: true,
            metadata: %{"rule_id" => rule_id(rule)}
          )
        end)

      :defer ->
        pending_state = if target_level == "peer", do: "provisional", else: "held"

        updated =
          transition!(
            knowledge,
            actor,
            %{
              state: pending_state,
              target_level: target_level,
              verification: "pending_human",
              held_scope_id: target_scope_id
            },
            reason: "f4_gate_a_b_deferred",
            channel: "pipeline"
          )

        validation =
          enqueue_validation!(
            updated,
            actor,
            target_level,
            target_scope_id,
            due_at,
            "gate_a_b"
          )

        if target_level == "peer" && is_binary(updated.subject_peer_id) do
          PeerQueue.enqueue!(updated, validation, "confirm", actor)
        end

        if consent_required?(updated, rule, target_level) && is_binary(target_scope_id) do
          request_consent!(updated, target_scope_id, actor)
        end

        record_decision!(
          actor,
          updated,
          validation.id,
          "gate_a",
          "defer",
          from_state: knowledge.state,
          to_state: updated.state,
          to_level: target_level,
          channel: "pipeline",
          verified: false,
          metadata: %{"rule_id" => rule_id(rule)}
        )

        record_decision!(
          actor,
          updated,
          validation.id,
          "gate_b",
          if(target_level == "peer", do: "provisional", else: "hold"),
          from_state: knowledge.state,
          to_state: updated.state,
          to_level: target_level,
          channel: "pipeline",
          verified: false,
          metadata: %{"rule_id" => rule_id(rule)}
        )

        updated
    end
  end

  def decide(actor, validation_id, action, opts \\ %{})
      when is_binary(validation_id) and action in @human_actions do
    require_human_curator!(actor)
    opts = stringify_keys(opts)

    DataLayer.with_actor(actor, fn account, current_actor ->
      Lock.acquire!(account.id, "validation:#{validation_id}")
      validation = validation!(account.id, current_actor, validation_id)
      knowledge = knowledge!(account.id, current_actor, validation.knowledge_id)

      case action do
        "approve" -> approve!(knowledge, validation, current_actor, opts)
        "edit" -> edit!(knowledge, validation, current_actor, opts)
        "reject" -> reject!(knowledge, validation, current_actor)
        "merge" -> merge!(knowledge, validation, current_actor, opts)
        "defer" -> defer!(knowledge, validation, current_actor, opts)
      end
    end)
  end

  def bulk_decide(actor, validation_ids, action, opts \\ %{})
      when is_list(validation_ids) and action in @human_actions do
    Enum.map(validation_ids, fn validation_id ->
      {validation_id, decide(actor, validation_id, action, opts)}
    end)
  end

  def request_promotion(actor, knowledge_id, target_scope_id) do
    require_human_curator!(actor)

    DataLayer.with_actor(actor, fn account, current_actor ->
      knowledge = knowledge!(account.id, current_actor, knowledge_id)
      source_scope = scope!(account.id, current_actor, knowledge.scope_id)
      target_scope = scope!(account.id, current_actor, target_scope_id)

      require_scope_curator!(current_actor, target_scope_id)

      unless wider_scope?(source_scope.path, target_scope.path),
        do: raise(ArgumentError, "Gate B promotion target must be a strict ancestor scope")

      held =
        transition!(
          knowledge,
          current_actor,
          %{state: "held", target_level: "scope", held_scope_id: target_scope_id},
          reason: "f4_gate_b_promotion_requested",
          channel: "human_ui"
        )

      due_at = DateTime.add(Clock.utc_now(), 168, :hour)

      validation =
        enqueue_validation!(held, current_actor, "scope", target_scope_id, due_at, "gate_b")

      result =
        if held.sensitivity == "personal" && is_binary(held.subject_peer_id) do
          consent = request_consent!(held, target_scope_id, pipeline_actor(current_actor))
          PeerQueue.enqueue!(held, validation, "consent_upward", pipeline_actor(current_actor))
          %{knowledge: held, validation: validation, consent: consent}
        else
          %{knowledge: held, validation: validation, consent: nil}
        end

      record_decision!(
        current_actor,
        held,
        validation.id,
        "gate_b",
        "hold",
        from_state: knowledge.state,
        to_state: held.state,
        to_level: "scope",
        channel: "human_ui",
        verified: true,
        metadata: %{
          "from_level" => knowledge.target_level,
          "target_scope_id" => target_scope_id,
          "consent_required" => !is_nil(result.consent)
        }
      )

      result
    end)
  end

  def subject_consent(actor, knowledge_id, target_scope_id, verdict, verified, channel)
      when verdict in ["grant", "deny"] do
    DataLayer.with_actor(actor, fn account, current_actor ->
      consent =
        Consent
        |> Ash.Query.filter(
          knowledge_id == ^knowledge_id and target_scope_id == ^target_scope_id and
            subject_peer_id == ^current_actor.peer_id
        )
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read_one!(actor: current_actor)

      if is_nil(consent), do: raise(Ash.Error.Query.NotFound, resource: Consent)

      if verdict == "grant" && !verified do
        {:error, :verified_channel_required}
      else
        updated =
          consent
          |> Ash.Changeset.for_update(:decide, %{
            status: if(verdict == "grant", do: "granted", else: "denied"),
            channel: channel,
            verified: verified,
            decided_by_peer_id: current_actor.peer_id,
            decided_at: Clock.utc_now()
          })
          |> Ash.Changeset.set_tenant(account.id)
          |> Ash.update!(actor: consent_actor(current_actor))

        Audit.append!(current_actor, account.id, %{
          scope_id: updated.scope_id,
          actor_peer_id: current_actor.peer_id,
          category: "gate",
          action: "consent.#{updated.status}",
          resource_type: "knowledge_consent",
          resource_id: updated.id,
          metadata: %{
            "knowledge_id" => knowledge_id,
            "target_scope_id" => target_scope_id,
            "channel" => channel,
            "verified" => verified
          }
        })

        {:ok, updated}
      end
    end)
  end

  def history(actor, knowledge_id) do
    DataLayer.with_actor(actor, fn account, current_actor ->
      knowledge = knowledge!(account.id, current_actor, knowledge_id)

      decisions =
        GateDecision
        |> Ash.Query.filter(knowledge_id == ^knowledge.id)
        |> Ash.Query.sort(decided_at: :asc)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read!(actor: history_actor(current_actor))

      lifecycle =
        Cartulary.Knowledge.LifecycleEvent
        |> Ash.Query.filter(knowledge_item_id == ^knowledge.id)
        |> Ash.Query.sort(occurred_at: :asc)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read!(actor: pipeline_actor(current_actor))

      %{knowledge: knowledge, gate_decisions: decisions, lifecycle: lifecycle}
    end)
  end

  def self_view(actor) when is_binary(actor.peer_id) do
    DataLayer.with_actor(actor, fn account, current_actor ->
      KnowledgeItem
      |> Ash.Query.filter(subject_peer_id == ^current_actor.peer_id and is_nil(deleted_at))
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.set_tenant(account.id)
      |> Ash.read!(actor: current_actor)
    end)
  end

  def contest(actor, knowledge_id, action) when action in ["confirm", "contest", "redact"] do
    DataLayer.with_actor(actor, fn account, current_actor ->
      knowledge = knowledge!(account.id, current_actor, knowledge_id)

      if knowledge.subject_peer_id != current_actor.peer_id do
        raise Ash.Error.Query.NotFound, resource: KnowledgeItem
      end

      case action do
        "confirm" ->
          updated =
            transition!(
              knowledge,
              pipeline_actor(current_actor),
              %{state: "active", verification: "subject_confirmed", confidence: 1.0},
              reason: "f4_subject_confirmed",
              channel: "self_view"
            )

          audit_subject_action!(current_actor, updated, action)
          updated

        "contest" ->
          updated =
            transition!(
              knowledge,
              pipeline_actor(current_actor),
              %{state: "contested", verification: "subject_disputed"},
              reason: "f4_subject_contested",
              channel: "self_view"
            )

          enqueue_validation!(
            updated,
            pipeline_actor(current_actor),
            updated.target_level,
            updated.held_scope_id,
            DateTime.add(Clock.utc_now(), 24, :hour),
            "contest"
          )

          audit_subject_action!(current_actor, updated, action)
          updated

        "redact" ->
          updated =
            transition!(
              knowledge,
              pipeline_actor(current_actor),
              %{state: "redacted", verification: "subject_redacted"},
              reason: "f4_subject_redacted",
              channel: "self_view"
            )

          audit_subject_action!(current_actor, updated, action)
          updated
      end
    end)
  end

  def transition!(knowledge, actor, attrs, opts) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put(:reason, Keyword.fetch!(opts, :reason))
      |> Map.put(:channel, Keyword.get(opts, :channel, "governance"))

    knowledge
    |> Ash.Changeset.for_update(:transition, attrs)
    |> Ash.Changeset.set_tenant(knowledge.account_id)
    |> Ash.update!(actor: actor)
  end

  def record_decision!(
        actor,
        knowledge,
        validation_item_id,
        gate,
        decision,
        attrs
      ) do
    from_state = Keyword.fetch!(attrs, :from_state)
    to_state = Keyword.fetch!(attrs, :to_state)
    to_level = Keyword.fetch!(attrs, :to_level)
    channel = Keyword.fetch!(attrs, :channel)
    verified = Keyword.fetch!(attrs, :verified)
    metadata = Keyword.get(attrs, :metadata, %{})

    decision_row =
      GateDecision
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_tenant(knowledge.account_id)
      |> Ash.Changeset.for_create(:record, %{
        validation_item_id: validation_item_id,
        knowledge_id: knowledge.id,
        scope_id: knowledge.scope_id,
        gate: gate,
        decision: decision,
        actor_peer_id: Map.get(actor, :peer_id),
        channel: channel,
        verified: verified,
        from_state: from_state,
        to_state: to_state,
        from_level: Map.get(metadata, "from_level", knowledge.target_level),
        to_level: to_level,
        statement_hash: knowledge.statement_hash,
        metadata: metadata,
        decided_at: Clock.utc_now()
      })
      |> Ash.create!(actor: actor)

    Audit.append!(actor, knowledge.account_id, %{
      scope_id: knowledge.scope_id,
      actor_peer_id: Map.get(actor, :peer_id),
      category: "gate",
      action: "#{gate}.#{decision}",
      resource_type: "gate_decision",
      resource_id: decision_row.id,
      content_hash: knowledge.statement_hash,
      metadata: %{
        "knowledge_id" => knowledge.id,
        "validation_item_id" => validation_item_id,
        "from_state" => from_state,
        "to_state" => to_state,
        "to_level" => to_level,
        "channel" => channel,
        "verified" => verified
      }
    })

    {:ok, _run} =
      Pipeline.enqueue(
        "validation_continuation",
        knowledge.account_id,
        %{
          scope_id: knowledge.scope_id,
          target_type: "gate_decision",
          target_id: decision_row.id,
          idempotency_key: Idempotency.validation_continuation(decision_row.id, knowledge.id),
          payload: %{
            "knowledge_id" => knowledge.id,
            "gate" => gate,
            "decision" => decision
          }
        },
        actor
      )

    decision_row
  end

  defp approve!(knowledge, validation, actor, _opts) do
    consent = consent_for(knowledge, validation, actor)

    if knowledge.sensitivity == "personal" && validation.target_level == "scope" &&
         (!consent || consent.status != "granted" || !consent.verified) do
      validation =
        update_validation!(validation, actor, %{
          state: "awaiting_consent",
          decision: "approve",
          decided_at: Clock.utc_now()
        })

      record_decision!(
        actor,
        knowledge,
        validation.id,
        "gate_b",
        "await_consent",
        from_state: knowledge.state,
        to_state: "held",
        to_level: validation.target_level,
        channel: "human_ui",
        verified: true
      )

      %{knowledge: knowledge, validation: validation, consent_required: true}
    else
      attrs =
        if validation.target_level == "scope" do
          %{
            scope_id: validation.target_scope_id,
            state: "active",
            target_level: "scope",
            held_scope_id: nil,
            verification: "curator_approved"
          }
        else
          %{state: "active", verification: "curator_approved"}
        end

      updated =
        transition!(knowledge, actor, attrs,
          reason: "f4_curator_approved",
          channel: "human_ui"
        )

      validation =
        update_validation!(validation, actor, %{
          state: "approved",
          decision: "approve",
          decided_at: Clock.utc_now()
        })

      record_decision!(
        actor,
        updated,
        validation.id,
        "gate_a_b",
        "approve",
        from_state: knowledge.state,
        to_state: updated.state,
        to_level: validation.target_level,
        channel: "human_ui",
        verified: true
      )

      %{knowledge: updated, validation: validation, consent_required: false}
    end
  end

  defp reject!(knowledge, validation, actor) do
    updated =
      transition!(
        knowledge,
        actor,
        %{state: "rejected", verification: "curator_rejected"},
        reason: "f4_curator_rejected",
        channel: "human_ui"
      )

    validation =
      update_validation!(validation, actor, %{
        state: "rejected",
        decision: "reject",
        decided_at: Clock.utc_now()
      })

    record_decision!(
      actor,
      updated,
      validation.id,
      "gate_a_b",
      "reject",
      from_state: knowledge.state,
      to_state: updated.state,
      to_level: validation.target_level,
      channel: "human_ui",
      verified: true
    )

    %{knowledge: updated, validation: validation}
  end

  defp defer!(knowledge, validation, actor, opts) do
    hours = opts |> Map.get("defer_hours", 24) |> normalize_positive_integer(24)

    validation =
      update_validation!(validation, actor, %{
        state: "deferred",
        decision: "defer",
        due_at: DateTime.add(Clock.utc_now(), hours, :hour)
      })

    record_decision!(
      actor,
      knowledge,
      validation.id,
      "gate_a_b",
      "defer",
      from_state: knowledge.state,
      to_state: knowledge.state,
      to_level: validation.target_level,
      channel: "human_ui",
      verified: true,
      metadata: %{"defer_hours" => hours}
    )

    %{knowledge: knowledge, validation: validation}
  end

  defp edit!(knowledge, validation, actor, opts) do
    statement = opts |> Map.fetch!("statement") |> String.trim()

    if statement == "", do: raise(ArgumentError, "edited statement cannot be blank")

    pipeline = pipeline_actor(actor)

    replacement =
      KnowledgeItem
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_tenant(knowledge.account_id)
      |> Ash.Changeset.for_create(:create_from_pipeline, %{
        scope_id: knowledge.scope_id,
        subject_peer_id: knowledge.subject_peer_id,
        subject_scope_id: knowledge.subject_scope_id,
        statement: statement,
        kind: knowledge.kind,
        confidence: knowledge.confidence,
        sensitivity: Map.get(opts, "sensitivity", knowledge.sensitivity),
        state: "proposed",
        target_level: knowledge.target_level,
        held_scope_id: knowledge.held_scope_id,
        supersedes_id: knowledge.id,
        source_message_ids: knowledge.source_message_ids,
        extracting_model: "human:curator-edit",
        pipeline_version: "f4-1"
      })
      |> Ash.create!(actor: pipeline)

    superseded =
      transition!(
        knowledge,
        pipeline,
        %{state: "superseded", verification: "curator_edited"},
        reason: "f4_curator_edit_superseded",
        channel: "human_ui"
      )

    validation =
      update_validation!(validation, actor, %{
        state: "approved",
        decision: "edit",
        decided_at: Clock.utc_now()
      })

    evaluated = evaluate_proposal(replacement, pipeline, target_level: knowledge.target_level)

    record_decision!(
      actor,
      superseded,
      validation.id,
      "gate_a_b",
      "edit",
      from_state: knowledge.state,
      to_state: superseded.state,
      to_level: knowledge.target_level,
      channel: "human_ui",
      verified: true,
      metadata: %{"replacement_id" => evaluated.id}
    )

    %{knowledge: superseded, replacement: evaluated, validation: validation}
  end

  defp merge!(knowledge, validation, actor, opts) do
    target_id = Map.fetch!(opts, "merge_into_id")
    target = knowledge!(knowledge.account_id, actor, target_id)
    pipeline = pipeline_actor(actor)

    target =
      target
      |> Ash.Changeset.for_update(:merge_from_pipeline, %{
        confidence: max(target.confidence, knowledge.confidence),
        corroboration_count: target.corroboration_count + knowledge.corroboration_count,
        source_message_ids: Enum.uniq(target.source_message_ids ++ knowledge.source_message_ids)
      })
      |> Ash.Changeset.set_tenant(knowledge.account_id)
      |> Ash.update!(actor: pipeline)

    merged =
      transition!(
        knowledge,
        pipeline,
        %{state: "superseded", supersedes_id: target.id, verification: "curator_merged"},
        reason: "f4_curator_merged",
        channel: "human_ui"
      )

    validation =
      update_validation!(validation, actor, %{
        state: "merged",
        decision: "merge",
        decided_at: Clock.utc_now()
      })

    record_decision!(
      actor,
      merged,
      validation.id,
      "gate_a_b",
      "merge",
      from_state: knowledge.state,
      to_state: merged.state,
      to_level: knowledge.target_level,
      channel: "human_ui",
      verified: true,
      metadata: %{"merge_into_id" => target.id}
    )

    %{knowledge: merged, merge_target: target, validation: validation}
  end

  defp matching_rule(knowledge, target_level, actor) do
    rules =
      GateRule
      |> Ash.Query.filter(
        target_level == ^target_level and sensitivity == ^knowledge.sensitivity and active == true
      )
      |> Ash.Query.sort(priority: :desc, version: :desc)
      |> Ash.Query.set_tenant(knowledge.account_id)
      |> Ash.read!(actor: actor)

    Enum.find(rules, &(&1.scope_id == knowledge.scope_id)) ||
      Enum.find(rules, &is_nil(&1.scope_id)) ||
      default_rule(target_level, knowledge.sensitivity)
  end

  defp default_rule(target_level, sensitivity) do
    %{
      id: nil,
      target_level: target_level,
      sensitivity: sensitivity,
      minimum_confidence: 1.0,
      gate_a_mode: "human",
      gate_b_mode: "human",
      minimum_corroboration: if(target_level == "peer", do: 1, else: 2),
      requires_consent: sensitivity == "personal" && target_level != "peer",
      pending_max_age_hours: 168,
      revalidate_after_days: 90
    }
  end

  defp auto_gate_a?(knowledge, rule),
    do: rule.gate_a_mode == "auto_keep" && knowledge.confidence >= rule.minimum_confidence

  defp auto_gate_b?(knowledge, rule, _target_level),
    do:
      rule.gate_b_mode == "auto_place" &&
        knowledge.corroboration_count >= rule.minimum_corroboration

  defp proposal_outcome(_knowledge, %{gate_a_mode: "auto_reject"}, _target_level),
    do: :reject

  defp proposal_outcome(knowledge, rule, target_level) do
    if auto_gate_a?(knowledge, rule) && auto_gate_b?(knowledge, rule, target_level) &&
         consent_not_required?(knowledge, rule, target_level),
       do: :accept,
       else: :defer
  end

  defp consent_not_required?(knowledge, rule, target_level),
    do: !consent_required?(knowledge, rule, target_level)

  defp consent_required?(knowledge, rule, target_level),
    do:
      target_level != "peer" && knowledge.sensitivity == "personal" &&
        (rule.requires_consent || knowledge.sensitivity == "personal")

  defp enqueue_validation!(knowledge, actor, target_level, target_scope_id, due_at, kind) do
    ValidationItem
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_tenant(knowledge.account_id)
    |> Ash.Changeset.for_create(:enqueue, %{
      knowledge_id: knowledge.id,
      scope_id: knowledge.scope_id,
      subject_peer_id: knowledge.subject_peer_id,
      target_scope_id: target_scope_id,
      target_level: target_level,
      kind: kind,
      state: "pending",
      decision: nil,
      statement_hash: knowledge.statement_hash,
      confidence: knowledge.confidence,
      sensitivity: knowledge.sensitivity,
      provenance_ids: provenance_ids(knowledge, actor),
      conflict_knowledge_ids: conflict_ids(knowledge, actor),
      escalated_at: nil,
      attempt_count: 0,
      decided_at: nil,
      due_at: due_at
    })
    |> Ash.create!(actor: actor)
  end

  defp provenance_ids(knowledge, actor) do
    Provenance
    |> Ash.Query.filter(knowledge_item_id == ^knowledge.id)
    |> Ash.Query.set_tenant(knowledge.account_id)
    |> Ash.read!(actor: pipeline_actor(actor))
    |> Enum.map(& &1.id)
  end

  defp conflict_ids(knowledge, actor) do
    KnowledgeRelation
    |> Ash.Query.filter(
      kind == "conflict" and
        (source_knowledge_id == ^knowledge.id or target_knowledge_id == ^knowledge.id)
    )
    |> Ash.Query.set_tenant(knowledge.account_id)
    |> Ash.read!(actor: pipeline_actor(actor))
    |> Enum.map(fn relation ->
      if relation.source_knowledge_id == knowledge.id,
        do: relation.target_knowledge_id,
        else: relation.source_knowledge_id
    end)
    |> Enum.uniq()
  end

  defp request_consent!(knowledge, target_scope_id, actor) do
    Consent
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_tenant(knowledge.account_id)
    |> Ash.Changeset.for_create(:request, %{
      knowledge_id: knowledge.id,
      scope_id: knowledge.scope_id,
      subject_peer_id: knowledge.subject_peer_id,
      target_scope_id: target_scope_id,
      status: "pending"
    })
    |> Ash.create!(actor: actor)
  end

  defp consent_for(_knowledge, %{target_level: "peer"}, _actor), do: nil

  defp consent_for(knowledge, validation, actor) do
    Consent
    |> Ash.Query.filter(
      knowledge_id == ^knowledge.id and target_scope_id == ^validation.target_scope_id
    )
    |> Ash.Query.set_tenant(knowledge.account_id)
    |> Ash.read_one!(actor: history_actor(actor))
  end

  defp update_validation!(validation, actor, attrs) do
    validation
    |> Ash.Changeset.for_update(:decide, attrs)
    |> Ash.Changeset.set_tenant(validation.account_id)
    |> Ash.update!(actor: actor)
  end

  defp validation!(account_id, actor, id) do
    ValidationItem
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read_one!(actor: actor)
    |> case do
      nil -> raise Ash.Error.Query.NotFound, resource: ValidationItem
      item -> item
    end
  end

  defp knowledge!(account_id, actor, id) do
    KnowledgeItem
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read_one!(actor: actor)
    |> case do
      nil -> raise Ash.Error.Query.NotFound, resource: KnowledgeItem
      item -> item
    end
  end

  defp scope!(account_id, actor, id) do
    Scope
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read_one!(actor: pipeline_actor(actor))
    |> case do
      nil -> raise Ash.Error.Query.NotFound, resource: Scope
      scope -> scope
    end
  end

  defp audit_subject_action!(actor, knowledge, action) do
    Audit.append!(actor, knowledge.account_id, %{
      scope_id: knowledge.scope_id,
      actor_peer_id: actor.peer_id,
      category: "governance",
      action: "subject.#{action}",
      resource_type: "knowledge_item",
      resource_id: knowledge.id,
      content_hash: knowledge.statement_hash,
      metadata: %{"state" => knowledge.state}
    })
  end

  defp require_human_curator!(%{identity_kind: :password, role: role})
       when role in [:account_admin, :curator],
       do: :ok

  defp require_human_curator!(_actor), do: raise(Ash.Error.Forbidden, errors: [])

  defp require_scope_curator!(%{scope_roles: roles}, scope_id) when is_map(roles) do
    if Map.get(roles, scope_id) in [:account_admin, :curator],
      do: :ok,
      else: raise(Ash.Error.Forbidden, errors: [])
  end

  defp require_scope_curator!(_actor, _scope_id),
    do: raise(Ash.Error.Forbidden, errors: [])

  defp history_actor(%{identity_kind: :password, role: role} = actor)
       when role in [:account_admin, :curator],
       do: actor

  defp history_actor(actor), do: pipeline_actor(actor)

  defp consent_actor(%{identity_kind: :password} = actor), do: actor
  defp consent_actor(actor), do: pipeline_actor(actor)

  defp pipeline_actor(%Cartulary.Actor{} = actor),
    do: %{actor | role: :system, scope_ids: :all, pipeline?: true}

  defp pipeline_actor(actor),
    do: actor |> Map.put(:role, :system) |> Map.put(:pipeline?, true)

  defp revalidate_at(%{revalidate_after_days: nil}), do: nil

  defp revalidate_at(rule),
    do: DateTime.add(Clock.utc_now(), rule.revalidate_after_days, :day)

  defp rule_id(%{id: nil}), do: "default-human"
  defp rule_id(rule), do: rule.id

  defp wider_scope?(source_path, target_path) do
    source_path != target_path &&
      (target_path == "/" || String.starts_with?(source_path, target_path <> "/"))
  end

  defp normalize_positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp normalize_positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _other -> default
    end
  end

  defp normalize_positive_integer(_value, default), do: default

  defp stringify_keys(attrs), do: Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
end
