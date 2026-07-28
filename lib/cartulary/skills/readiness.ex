# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Skills.Readiness do
  @moduledoc """
  Decides whether a peer's governed memory already contains what a skill requires, and reports
  exactly what is missing.

  This is the pre-flight check an agent runs before executing a skill. It gathers the
  requirement cards on the path from the root scope to the target scope, merges them into one
  effective contract, and evaluates each requirement against the knowledge the caller is allowed
  to read.

  ## Reasoning-free

  Evaluation compares stored metadata: statement kind, subject, sensitivity, target level,
  verification state, confidence, corroboration count, and durable provenance. It never runs a
  model, never does text search, and never inspects statement wording. Two consequences follow
  and both are intentional: the answer is deterministic and cheap, and a requirement can only be
  expressed in terms of facts the system already records about a statement.

  ## What may satisfy a requirement

  Only `active` knowledge, or `provisional` knowledge whose subject is the peer being checked —
  a peer may rely on their own not-yet-approved material, nobody else's. `expired` and
  `needs_revalidation` rows are read too, but only so that a matching-but-unusable item can be
  reported as `stale` rather than as `missing`; they never satisfy anything.

  Staleness is computed from timestamps at check time, not from the lifecycle state alone. A row
  still labelled `active` whose `expires_at` or `revalidate_after` has passed is stale
  immediately. This closes the window a delayed background sweeper would otherwise open, in
  which knowledge everyone agrees is out of date still reads as current.

  A requirement may also demand recency directly. That window is measured against the most
  recent transition into `active` or `provisional` — an actual validation event — so touching
  a statement's embeddings or reindexing it cannot make it look freshly confirmed.

  ## Blockers and warnings

  A `required` requirement that is not satisfied is a blocker and the report comes back
  `ready: false, blocked: true`. A `preferred` requirement that is not satisfied is a warning
  and does not block. If no active card is visible for the skill at all, that is a blocker too:
  an absent contract fails closed rather than being read as permission.

  ## Elicitation is not a write path

  When a requirement's source policy allows asking the peer, its gap carries a prompt. Answering
  that prompt does not satisfy the requirement. The answer must be submitted as an ordinary raw
  observation, be extracted, and pass the approval gates; only a later readiness check can see
  it. Nothing in this module writes knowledge, and no client helper may treat a prompt as a
  shortcut around governance.

  ## Content safety

  The telemetry emitted here carries the report identity, three counts, and the final boolean.
  Skill names, card descriptions, selectors, statement text, matched content, and elicitation
  prompts must never be added to it.
  """

  alias Cartulary.Accounts.Peer
  alias Cartulary.Clock
  alias Cartulary.DataLayer
  alias Cartulary.Knowledge.KnowledgeItem
  alias Cartulary.Knowledge.LifecycleEvent
  alias Cartulary.Knowledge.Provenance
  alias Cartulary.Observability
  alias Cartulary.Observations.Message
  alias Cartulary.Skills.SkillRequirementCard
  alias Cartulary.Topology.Scope

  require Ash.Query

  # The identity of the readiness report, currently `f9-1` — the same string the selector
  # language carries, but a separate constant. Clients key their parsing off it. Changing it is
  # a deliberate contract transition: it means the report shape or the matching semantics
  # changed, and it obliges a changelog entry and updated client expectations.
  @report_version "f9-1"

  # States worth loading. `active` and `provisional` can satisfy a requirement;
  # `needs_revalidation` and `expired` cannot, and are read only so a requirement that would
  # otherwise match can be reported as `stale` instead of `missing` — the difference between
  # "nobody ever told us" and "what we were told has gone out of date".
  @readable_states ~w(active provisional needs_revalidation expired)

  @doc """
  Evaluates one skill's requirements for one peer at one scope and returns the gap report.

  `actor` must be a resolved, authenticated actor; the Account comes from that identity and is
  never taken from `attrs`. `attrs` may use string or atom keys and must carry:

  * `"skill"` — the skill key to check. Required.
  * `"scope_id"` or `"scope_path"` — the target scope. Required.
  * `"peer_id"` or `"peer_key"` — who is being checked. Optional when the actor is itself a
    peer, in which case that peer is used.

  Returns a string-keyed report containing the report version, the skill, the resolved peer and
  scope, `"ready"` and `"blocked"` booleans, the card versions that contributed, the effective
  `"requirements"` with a per-requirement status of `satisfied`, `stale`, or `missing`, the
  subsets that are `"blockers"` and `"warnings"`, and the check timestamp. Each requirement also
  reports the ids of the knowledge that satisfied it and of the knowledge that matched but was
  too stale to count. When no active card is visible, `"blockers"` additionally carries one
  synthetic entry that is not part of `"requirements"`.

  Raises `ArgumentError` when the skill, the scope, or the peer cannot be determined from
  `attrs`. Raises if an underlying Ash read fails; a scope or peer the caller may not read
  resolves to `nil` and then fails on the subsequent field access rather than silently widening
  the check.
  """
  def check_readiness(actor, attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    Observability.with_span(:skills, "cartulary.skills.check_readiness", fn ->
      report =
        DataLayer.with_actor(actor, fn account, current_actor ->
          # One Account-scoped transaction, which is what installs the Account setting the
          # row-level security policies read; every query below runs on that connection. It is
          # not a repeatable-read snapshot (the isolation level is the Postgres default), so a
          # concurrent governance decision can still land between two of these reads.
          scope = scope!(account.id, current_actor, attrs)
          peer = peer!(account.id, current_actor, attrs)
          scopes = ancestor_scopes(account.id, current_actor, scope.path)

          cards =
            account.id
            |> active_cards(current_actor, Enum.map(scopes, & &1.id), attrs)
            |> order_cards(scopes)

          requirements = effective_requirements(cards, scopes)

          knowledge =
            knowledge_candidates(
              account.id,
              current_actor,
              Enum.map(scopes, & &1.id),
              peer.id
            )

          evidence = evidence(account.id, current_actor, knowledge, peer.id)
          build_report(attrs, peer, scope, cards, requirements, knowledge, evidence)
        end)

      # Counts and one boolean only. Adding the skill key, a requirement key, a card
      # description, or any matched statement here would put user content into telemetry, which
      # is retained under different rules than knowledge and is not covered by erasure.
      Observability.set_attributes(:skills, %{
        "cartulary.readiness.report_version" => @report_version,
        "cartulary.readiness.requirement_count" => length(report["requirements"]),
        "cartulary.readiness.blocker_count" => length(report["blockers"]),
        "cartulary.readiness.warning_count" => length(report["warnings"]),
        "cartulary.readiness.ready" => report["ready"]
      })

      report
    end)
  end

  # Assembles the report. Every requirement appears in `requirements` with its own status;
  # `blockers` and `warnings` are views over that same list, split by whether an unsatisfied
  # requirement is `required` (blocks the skill) or `preferred` (only warns).
  defp build_report(attrs, peer, scope, cards, requirements, knowledge, evidence) do
    results =
      Enum.map(requirements, fn requirement ->
        evaluate(requirement, knowledge, evidence, peer.id)
      end)

    {blockers, warnings} =
      Enum.reduce(results, {[], []}, fn result, {blockers, warnings} ->
        cond do
          result["status"] == "satisfied" -> {blockers, warnings}
          result["level"] == "required" -> {[result | blockers], warnings}
          true -> {blockers, [result | warnings]}
        end
      end)

    # No visible active card is a blocker, never silent permission. A skill whose contract has
    # not been authored — or whose card lives in a scope this caller cannot read — must not
    # run as if it had no requirements. The synthetic key is namespaced so it cannot collide
    # with an authored requirement key, which the selector language constrains to a slug.
    blockers =
      if cards == [] do
        [
          %{
            "key" => "__skill_card__",
            "level" => "required",
            "source_policy" => "from-memory",
            "status" => "missing_card",
            "blocking" => true,
            "message" => "No active skill requirement card is visible for this scope.",
            "elicitation" => %{"allowed" => false}
          }
          | blockers
        ]
      else
        blockers
      end
      |> Enum.reverse()

    warnings = Enum.reverse(warnings)

    %{
      "report_version" => @report_version,
      "skill" => attrs["skill"],
      "peer_id" => peer.id,
      "scope_id" => scope.id,
      "scope_path" => scope.path,
      "ready" => blockers == [],
      "blocked" => blockers != [],
      "cards" => Enum.map(cards, &card_result/1),
      "requirements" => results,
      "blockers" => blockers,
      "warnings" => warnings,
      "checked_at" => DateTime.to_iso8601(Clock.utc_now())
    }
  end

  # Evaluates one requirement in two stages: first which statements match its selector at all,
  # then which of those are fresh enough to count. The split is what distinguishes the three
  # statuses — a `stale` result means "we have this, but it has gone out of date", which is
  # different advice to a human than "we never learned this".
  #
  # Only a satisfied requirement suppresses the elicitation descriptor. A stale requirement
  # still offers to ask, because re-asking is exactly how stale knowledge gets refreshed.
  defp evaluate(requirement, knowledge, evidence, peer_id) do
    selector = requirement["selector"]

    metadata_matches =
      Enum.filter(
        knowledge,
        &metadata_match?(&1, selector, requirement["source_policy"], evidence, peer_id)
      )

    {fresh, stale} =
      Enum.split_with(
        metadata_matches,
        &fresh?(&1, requirement["freshness"], evidence)
      )

    status =
      cond do
        fresh != [] -> "satisfied"
        stale != [] -> "stale"
        true -> "missing"
      end

    result = %{
      "key" => requirement["key"],
      "description" => requirement["description"],
      "level" => requirement["level"],
      "source_policy" => requirement["source_policy"],
      "selector" => selector,
      "freshness" => requirement["freshness"],
      "status" => status,
      "blocking" => status != "satisfied" and requirement["level"] == "required",
      "matched_knowledge_ids" => Enum.map(fresh, & &1.id),
      "stale_knowledge_ids" => Enum.map(stale, & &1.id),
      "source_scope_id" => requirement["_source_scope_id"],
      "source_scope_path" => requirement["_source_scope_path"],
      "card_version" => requirement["_card_version"]
    }

    if status == "satisfied" do
      Map.put(result, "elicitation", %{"allowed" => false})
    else
      Map.put(result, "elicitation", elicitation(requirement))
    end
  end

  # Every selector clause is a conjunction, and an absent clause matches everything. The
  # weakest selector an author can express is therefore the one normalization produces from an
  # omitted selector — subject only, defaulted to `either` — which means "we must know
  # *something* here, about this peer or about a scope". That is a meaningful requirement, not
  # an error.
  #
  # All nine clauses read stored metadata or durable provenance. None of them looks at statement
  # text, which is what keeps this evaluation deterministic and model-free.
  defp metadata_match?(item, selector, source_policy, evidence, peer_id) do
    value_match?(item.kind, selector["kind"]) and
      subject_match?(item, selector["subject"], peer_id) and
      value_match?(item.sensitivity, selector["sensitivity"]) and
      value_match?(item.target_level, selector["target_level"]) and
      value_match?(item.verification, selector["verification"]) and
      minimum?(item.confidence, selector["minimum_confidence"]) and
      minimum?(item.corroboration_count, selector["minimum_corroboration"]) and
      source_types_match?(item.id, selector["source_types"], evidence) and
      source_policy_match?(item.id, source_policy, evidence)
  end

  # `ask-peer` means the answer has to have come from this peer's own mouth: the statement needs
  # a message provenance whose author is the peer being checked. Something the system inferred,
  # or that a colleague reported, does not count. `from-memory` and `either` accept any governed
  # source that otherwise matches.
  defp source_policy_match?(knowledge_id, "ask-peer", evidence),
    do: MapSet.member?(evidence.peer_sourced_ids, knowledge_id)

  defp source_policy_match?(_knowledge_id, _source_policy, _evidence), do: true

  # Freshness has two independent halves and a statement must pass both.
  #
  # The lifecycle half re-derives usability from timestamps instead of trusting `state`. A row
  # labelled `active` whose `expires_at` or `revalidate_after` is already in the past is treated
  # as stale here and now, so the lag between expiry and the sweeper that relabels it cannot
  # produce a readiness answer everyone would call wrong. `needs_revalidation` and `expired`
  # rows fail this half by state, which is why they can only ever be reported as stale.
  #
  # The window half applies the requirement's own recency demand. It is measured against the
  # most recent transition into `active` or `provisional` — a real validation event — rather
  # than `updated_at`, so re-embedding or reindexing a statement cannot pass it off as recently
  # confirmed. A statement with no such transition on record fails the window rather than being
  # given the benefit of the doubt.
  defp fresh?(item, freshness, evidence) do
    now = Clock.utc_now()

    lifecycle_fresh? =
      item.state in ["active", "provisional"] and
        (is_nil(item.expires_at) or DateTime.compare(item.expires_at, now) == :gt) and
        (is_nil(item.revalidate_after) or DateTime.compare(item.revalidate_after, now) == :gt)

    within_window? =
      case freshness do
        %{"revalidated_within_seconds" => seconds} ->
          cutoff = DateTime.add(now, -seconds, :second)

          case evidence.last_validated_at[item.id] do
            %DateTime{} = validated_at -> DateTime.compare(validated_at, cutoff) in [:gt, :eq]
            nil -> false
          end

        _ ->
          true
      end

    lifecycle_fresh? and within_window?
  end

  # Subject is who the claim is *about*, never who said it. `peer` restricts to claims about the
  # peer being checked — another peer's preferences can never satisfy this peer's requirement.
  # `scope` restricts to claims about the place rather than about any person. There is no clause
  # for a missing subject because normalization always fills it in, defaulting to `either`.
  defp subject_match?(item, "peer", peer_id), do: item.subject_peer_id == peer_id

  defp subject_match?(item, "scope", _peer_id),
    do: is_binary(item.subject_scope_id)

  defp subject_match?(item, "either", peer_id),
    do: item.subject_peer_id == peer_id or is_binary(item.subject_scope_id)

  # An omitted selector clause is not a constraint. Selector values are always normalized to
  # lists, so membership is the only comparison needed.
  defp value_match?(_value, nil), do: true
  defp value_match?(value, allowed), do: value in allowed

  defp minimum?(_value, nil), do: true
  defp minimum?(value, minimum), do: value >= minimum

  # Source types are evaluated from durable provenance rows, not from anything on the statement
  # itself, so a statement's claimed origin cannot be spoofed by its own fields. A statement
  # with several provenances matches if *any* of them is one of the requested types.
  defp source_types_match?(_knowledge_id, nil, _evidence), do: true

  defp source_types_match?(knowledge_id, source_types, evidence) do
    evidence.source_types
    |> Map.get(knowledge_id, MapSet.new())
    |> MapSet.disjoint?(MapSet.new(source_types))
    |> Kernel.not()
  end

  # A descriptor, not an instruction to write anything. It tells the client that asking the peer
  # is permitted for this requirement, what to ask, and that the answer goes back in through
  # ordinary raw ingestion and must be re-checked afterwards. The answer becomes knowledge only
  # if extraction and the approval gates let it; a client that skips those steps and stores the
  # answer itself has bypassed governance.
  #
  # A `from-memory` requirement offers no prompt: it says the information must already have been
  # learned, so soliciting it on the spot would defeat the requirement.
  defp elicitation(%{"source_policy" => source_policy} = requirement)
       when source_policy in ["ask-peer", "either"] do
    %{
      "allowed" => true,
      "prompt" => requirement["prompt"],
      "submit_via" => "ingest",
      "then" => "check_readiness"
    }
  end

  defp elicitation(_requirement), do: %{"allowed" => false}

  # Merges the cards along the root-to-target path into one effective contract, nearest scope
  # wins.
  #
  # Cards are applied shallowest first — path string length is the depth proxy, since a
  # descendant's path is always longer than its ancestor's — so a nearer card's requirement
  # overwrites an inherited one with the same key. A requirement marked disabled acts as a
  # tombstone: it deletes the inherited key instead of adding anything, which is how a child
  # scope opts out of an ancestor's requirement without editing the ancestor's card.
  #
  # The parallel `order` list preserves first-seen key order so the report reads in a stable
  # sequence rather than in map order, and each surviving requirement is tagged with the scope
  # and card version it came from so a reader can tell where an inherited rule was authored.
  defp effective_requirements(cards, scopes) do
    scope_paths = Map.new(scopes, &{&1.id, &1.path})

    cards
    |> Enum.sort_by(&String.length(Map.fetch!(scope_paths, &1.scope_id)))
    |> Enum.reduce({%{}, []}, fn card, {requirements, order} ->
      Enum.reduce(card.requirements, {requirements, order}, fn requirement, {merged, keys} ->
        key = requirement["key"]

        if requirement["enabled"] do
          decorated =
            requirement
            |> Map.put("_source_scope_id", card.scope_id)
            |> Map.put("_source_scope_path", Map.fetch!(scope_paths, card.scope_id))
            |> Map.put("_card_version", card.version)

          {Map.put(merged, key, decorated), append_once(keys, key)}
        else
          {Map.delete(merged, key), List.delete(keys, key)}
        end
      end)
    end)
    |> then(fn {requirements, order} -> Enum.map(order, &Map.fetch!(requirements, &1)) end)
  end

  # At most one card per scope: the highest active version. Publishing already deactivates the
  # previous version, so more than one active row per scope means something went wrong; taking
  # the maximum version resolves it in favour of the newest contract rather than failing.
  #
  # The read runs under the caller's actor, so a card in an ancestor scope the caller cannot
  # read simply does not appear — and if that leaves no cards at all, the missing-card blocker
  # fires. Requiring the skill key here rather than defaulting it is deliberate: a readiness
  # check without a skill has no contract to check against.
  defp active_cards(account_id, actor, scope_ids, %{"skill" => skill}) when is_binary(skill) do
    SkillRequirementCard
    |> Ash.Query.filter(scope_id in ^scope_ids and skill_key == ^skill and active == true)
    |> Ash.Query.sort(version: :desc)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
    |> Enum.group_by(& &1.scope_id)
    |> Enum.map(fn {_scope_id, cards} -> Enum.max_by(cards, & &1.version) end)
  end

  defp active_cards(_account_id, _actor, _scope_ids, _attrs),
    do: raise(ArgumentError, "skill is required")

  # The candidate pool: everything in the target scope and its authorized ancestors that is in a
  # state worth examining. Ash applies the Account tenant and the caller's scope authorization,
  # and the extra filter here enforces the rule policies cannot express — a `provisional`
  # statement is usable only by the peer it is about. Held, proposed, and rejected states are
  # excluded by the state list, so ungoverned material can never satisfy a requirement.
  defp knowledge_candidates(account_id, actor, scope_ids, peer_id) do
    KnowledgeItem
    |> Ash.Query.filter(scope_id in ^scope_ids and state in ^@readable_states)
    |> Ash.Query.sort(inserted_at: :desc, id: :asc)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
    |> Enum.filter(fn item ->
      item.state != "provisional" or item.subject_peer_id == peer_id
    end)
  end

  # Loads, in at most three batched reads, the facts about the candidate statements that are not
  # stored on the statements themselves:
  #
  #   * `source_types` — which kinds of source produced each statement, from its provenance
  #     rows, for the `source_types` selector clause.
  #   * `peer_sourced_ids` — the statements traceable to a message the checked peer wrote, which
  #     is what an `ask-peer` requirement demands.
  #   * `last_validated_at` — the most recent transition into `active` or `provisional` per
  #     statement, used as the freshness watermark. Taken from the lifecycle history rather than
  #     `updated_at` so only a real validation resets the clock.
  #
  # Batched deliberately: doing this per requirement would issue a query per requirement per
  # statement, and this check runs before every skill invocation.
  defp evidence(_account_id, _actor, [], _peer_id),
    do: %{source_types: %{}, peer_sourced_ids: MapSet.new(), last_validated_at: %{}}

  defp evidence(account_id, actor, knowledge, peer_id) do
    knowledge_ids = Enum.map(knowledge, & &1.id)

    provenances =
      Provenance
      |> Ash.Query.filter(knowledge_item_id in ^knowledge_ids)
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read!(actor: actor)

    last_validated_at =
      LifecycleEvent
      |> Ash.Query.filter(
        knowledge_item_id in ^knowledge_ids and to_state in ["active", "provisional"]
      )
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read!(actor: actor)
      |> Enum.group_by(& &1.knowledge_item_id, & &1.occurred_at)
      |> Map.new(fn {knowledge_id, timestamps} ->
        {knowledge_id, Enum.max(timestamps, DateTime)}
      end)

    message_ids =
      provenances
      |> Enum.map(& &1.message_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    peer_message_ids =
      if message_ids == [] do
        MapSet.new()
      else
        Message
        |> Ash.Query.filter(id in ^message_ids and peer_id == ^peer_id)
        |> Ash.Query.set_tenant(account_id)
        |> Ash.read!(actor: actor)
        |> Enum.map(& &1.id)
        |> MapSet.new()
      end

    source_types =
      provenances
      |> Enum.group_by(& &1.knowledge_item_id, & &1.source_type)
      |> Map.new(fn {knowledge_id, types} -> {knowledge_id, MapSet.new(types)} end)

    peer_sourced_ids =
      provenances
      |> Enum.filter(&MapSet.member?(peer_message_ids, &1.message_id))
      |> Enum.map(& &1.knowledge_item_id)
      |> MapSet.new()

    %{
      source_types: source_types,
      peer_sourced_ids: peer_sourced_ids,
      last_validated_at: last_validated_at
    }
  end

  # The target scope plus every ancestor the caller may read, shallowest first. Sorting by path
  # ascending yields root-to-target order, which `order_cards/2` uses to report the cards along
  # the inheritance path. Ancestors the caller cannot read are absent rather than an error:
  # their requirements simply do not apply to a caller who cannot see that part of the tree.
  defp ancestor_scopes(account_id, actor, path) do
    paths = ancestor_paths(path)

    Scope
    |> Ash.Query.filter(path in ^paths)
    |> Ash.Query.sort(path: :asc)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
  end

  # Scope may be named by id or by path; the lookup is Account-scoped and runs under the
  # caller's actor, so an id belonging to another Account or to an unauthorized scope resolves
  # to nil rather than to someone else's scope.
  defp scope!(account_id, actor, %{"scope_id" => id}) when is_binary(id) do
    Scope
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read_one!(actor: actor)
  end

  defp scope!(account_id, actor, %{"scope_path" => path}) when is_binary(path) do
    Scope
    |> Ash.Query.filter(path == ^normalize_path(path))
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read_one!(actor: actor)
  end

  defp scope!(_account_id, _actor, _attrs),
    do: raise(ArgumentError, "scope_id or scope_path is required")

  # Peer resolution order: an explicitly named peer id, then a peer key, then the calling
  # actor's own peer. Readiness is per-peer because a peer's own provisional knowledge counts
  # for them and for nobody else, so getting this wrong would judge one person's readiness with
  # another person's memory. Naming a peer is still Account-scoped and authorized like any other
  # read.
  defp peer!(account_id, actor, %{"peer_id" => id}) when is_binary(id) do
    Peer
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read_one!(actor: actor)
  end

  defp peer!(account_id, actor, %{"peer_key" => key}) when is_binary(key) do
    Peer
    |> Ash.Query.filter(key == ^key)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read_one!(actor: actor)
  end

  defp peer!(account_id, %{peer_id: peer_id} = actor, _attrs) when is_binary(peer_id) do
    peer!(account_id, actor, %{"peer_id" => peer_id})
  end

  defp peer!(_account_id, _actor, _attrs),
    do: raise(ArgumentError, "peer_id or peer_key is required")

  # Card identity only: which card versions this answer was computed from. Deliberately without
  # the description or the requirement bodies — those already appear, merged and attributed, in
  # the report's requirement list, and repeating the raw card here would ship inherited rules
  # the caller's effective contract had switched off.
  defp card_result(card) do
    %{
      "id" => card.id,
      "scope_id" => card.scope_id,
      "version" => card.version,
      "requirement_schema_version" => card.requirement_schema_version
    }
  end

  # Reports cards in scope order (root first) rather than in database order, so the reported
  # card list reads along the inheritance path.
  defp order_cards(cards, scopes) do
    order =
      scopes
      |> Enum.with_index()
      |> Map.new(fn {scope, index} -> {scope.id, index} end)

    Enum.sort_by(cards, &Map.fetch!(order, &1.scope_id))
  end

  # Expands a scope path into itself and every ancestor, root included. The root "/" is
  # prepended explicitly because splitting on "/" discards it, and an account-wide card lives
  # there.
  defp ancestor_paths(path) do
    path
    |> normalize_path()
    |> String.split("/", trim: true)
    |> Enum.scan("", fn segment, prefix -> prefix <> "/" <> segment end)
    |> then(&["/" | &1])
  end

  # Canonical form: exactly one leading slash, no trailing slash, root stays "/". Paths are
  # compared as strings against stored scope paths, so an unnormalized value would silently miss
  # the scope instead of failing loudly.
  defp normalize_path(path) do
    normalized = "/" <> (path |> to_string() |> String.trim() |> String.trim("/"))
    if normalized == "/", do: "/", else: normalized
  end

  # Keeps a requirement key at its first-seen position when a nearer scope overrides it, so
  # overriding a rule does not move it to the end of the report.
  defp append_once(keys, key), do: if(key in keys, do: keys, else: keys ++ [key])
  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
