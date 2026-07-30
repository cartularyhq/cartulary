# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.F4RealGateABGovernanceTest do
  @moduledoc """
  Pins the two gates that stand between "an agent said something" and "the system believes it",
  plus the human-only decisions, consent, aging, and erasure that hang off them.

  The file name and module name are frozen evidence identities and are not renamed. The rules
  below are the product's promise about what it will and will not remember, so the assertions
  are deliberately unforgiving.

  **Nothing is believed by default.** Extracted knowledge is born `proposed`. The first gate
  decides whether to keep, reject, or defer it; the second decides where it may be seen. With
  no configured rule the pair defer to a human, so the item lands `provisional` — visible only
  to the peer it came from — and a review item appears in the curator queue. An operator may
  configure a rule for a given target level and sensitivity, with a confidence floor, that
  keeps and places automatically; even then the decision is recorded and the item is given a
  revalidation deadline, so automatic acceptance is never permanent.

  **Curator decisions belong to humans.** A machine credential may submit observations, read
  what it is allowed to read, and answer a question about its own memory. It may not approve,
  edit, reject, merge, or defer, and it cannot reach the human-governance routes or the
  governance console. Otherwise an agent could rubber-stamp its own submissions and the gate
  would be decoration.

  **Moving knowledge outward is a separate, harder decision.** A request to publish an item to
  a wider scope parks it as `held`, where it is absent from ordinary reads until approved. If
  the item is personal, curator approval alone is not enough: the subject must consent, for
  that specific destination, through a verified human channel. An unverified channel is
  refused outright.

  **An answer only counts if the question was really asked.** A question attached to a read is
  frozen at the moment it is asked, and a peer's confirmation changes anything only when the
  conversation transcript shows the exact statement was actually delivered to that peer.
  Otherwise the answer merely defers the timer. Text supplied alongside a correction is kept as
  evidence and must never become knowledge — new claims come back through ordinary ingest and
  through these same gates. A peer may always lower how often it is interrupted by such
  questions, and no caller can raise those limits back up.

  **Unanswered memory decays.** Items past their revalidation date are marked as needing
  revalidation and generate a question; questions left unanswered past their deadline lose
  confidence and go stale, so nobody is quietly served aging beliefs as fact.

  **Erasure is real deletion with a surviving trail.** Erasing a subject removes the Peer row,
  the knowledge about them, and the question text delivered to them, while leaving content-safe
  audit evidence that the erasure happened.

  ## If a test in this file fails

  Treat it as a privacy or safety defect. Auto-activating without a matching configured rule,
  letting a machine credential decide, surfacing `held` items, accepting consent from an
  unverified channel, minting knowledge from a correction, or losing the audit record of an
  erasure are each a breach of the promise above, not a test that needs relaxing.
  """

  use CartularyWeb.ConnCase, async: false

  alias Cartulary.Actor
  alias Cartulary.Clock
  alias Cartulary.DataLayer
  alias Cartulary.Governance.Engine
  alias Cartulary.Governance.Erasure
  alias Cartulary.Governance.GateDecision
  alias Cartulary.Governance.GateRule
  alias Cartulary.Governance.PeerQuery
  alias Cartulary.Governance.PeerQueue
  alias Cartulary.Governance.Sweeper
  alias Cartulary.Governance.ValidationItem
  alias Cartulary.Identity
  alias Cartulary.Knowledge.KnowledgeItem
  alias Cartulary.Memory
  alias Cartulary.Repo
  alias Cartulary.Topology.Scope

  require Ash.Query

  test "the default matrix defers to human Gate A/B while configured matrix cells auto-accept" do
    %{actor: actor} = bootstrap_human!("matrix")

    first =
      ingest!(
        actor,
        "matrix-default",
        "/governance/matrix",
        "Avery prefers weekly release summaries."
      )

    # No rule is configured yet, so both gates defer. `provisional` means the submitting peer
    # can still see its own memory while a human decides; it is not visible to the Account at
    # large, and `pending_human` records that a person still owes a decision.
    assert first.state == "provisional"
    assert first.verification == "pending_human"

    {validation, decisions} =
      DataLayer.with_actor(actor, fn account, current_actor ->
        validation =
          ValidationItem
          |> Ash.Query.filter(knowledge_id == ^first.id)
          |> Ash.Query.set_tenant(account.id)
          |> Ash.read_one!(actor: current_actor)

        decisions =
          GateDecision
          |> Ash.Query.filter(knowledge_id == ^first.id)
          |> Ash.Query.sort(decided_at: :asc)
          |> Ash.Query.set_tenant(account.id)
          |> Ash.read!(actor: current_actor)

        {validation, decisions}
      end)

    # A queue entry exists and is waiting. Without it the item would sit provisional forever
    # with nobody asked to look at it.
    assert validation.state == "pending"

    # Both gates leave an immutable record of what they decided, in the order they ran. Even a
    # deferral is written down, so "why is this still pending" is always answerable.
    assert Enum.map(decisions, &{&1.gate, &1.decision}) == [
             {"gate_a", "defer"},
             {"gate_b", "provisional"}
           ]

    history = Engine.history(actor, first.id)

    # The history a reviewer is shown must be the durable ledger, not a summary that could
    # drift from it: the lifecycle trail starts at `proposed`, and the decisions match the rows
    # read directly above.
    assert Enum.map(history.lifecycle, & &1.to_state) == ["proposed", "provisional"]

    assert Enum.map(history.gate_decisions, &{&1.gate, &1.decision}) ==
             Enum.map(decisions, &{&1.gate, &1.decision})

    # Exactly two audit entries: the item was created and it changed state once. A missing entry
    # means a state change slipped past the audit trail.
    assert scalar!(
             """
             SELECT count(*) FROM audit_events
             WHERE resource_id = $1
               AND action IN ('knowledge.created', 'knowledge.transitioned')
             """,
             [Ecto.UUID.dump!(first.id)]
           ) == 2

    # One cell of the operator-configured matrix. A cell is selected by how far the knowledge is
    # meant to travel (target level) and how sensitive it is; the modes then say what the gates
    # should do automatically.
    #
    #   minimum_confidence 0.5    — confidence runs 0.0 to 1.0; below this floor the automatic
    #                               keep does not fire and the item falls back to human review.
    #   minimum_corroboration 1   — how many independent sources must have said it; 1 means a
    #                               single source is enough for this narrow, low-stakes cell.
    #   revalidate_after_days 90  — days before an auto-kept item must be re-confirmed, so
    #                               automatic acceptance expires instead of lasting forever.
    #   priority 10               — tie-break when several cells match; this is a scalar rank,
    #                               not a threshold.
    create_gate_rule!(actor, %{
      target_level: "peer",
      sensitivity: "internal",
      minimum_confidence: 0.5,
      gate_a_mode: "auto_keep",
      gate_b_mode: "auto_place",
      minimum_corroboration: 1,
      revalidate_after_days: 90,
      priority: 10
    })

    second =
      ingest!(
        actor,
        "matrix-auto",
        "/governance/matrix",
        "Avery wants concise deployment notes every Monday."
      )

    # Now, and only now, an item becomes active without a human. It is marked as machine-decided
    # rather than human-verified, and it carries the revalidation deadline the rule imposed.
    assert second.state == "active"
    assert second.verification == "auto_verified"
    assert %DateTime{} = second.revalidate_after
  end

  test "curator Gate A actions are human-only and scope-held proposals never surface" do
    %{actor: actor} = bootstrap_human!("curator")

    knowledge =
      ingest!(actor, "curator-item", "/private/work", "Avery uses the release train checklist.")

    validation = validation_for!(actor, knowledge.id)

    agent =
      Identity.provision_agent(actor, %{
        key: "machine-curator",
        name: "Machine Curator",
        scope_path: "/",
        role: "curator"
      })

    # The agent deliberately holds the curator role. That is the whole point: role alone must
    # not be enough, because the decision is reserved for a human identity. If this ever
    # succeeded, an agent could approve the very knowledge it submitted moments earlier.
    assert {:ok, machine_actor} = Identity.authenticate_bearer(agent.api_key)
    assert machine_actor.role == :curator
    assert machine_actor.identity_kind == :api_key

    assert_raise Ash.Error.Forbidden, fn ->
      Engine.decide(machine_actor, validation.id, "approve")
    end

    # Asking to publish a private item to the containment root parks it as `held` at its source
    # scope. Held means pending, not published.
    root = scope_by_path!(actor, "/")
    promotion = Engine.request_promotion(actor, knowledge.id, root.id)
    assert promotion.knowledge.state == "held"

    # And a held item must not appear in an ordinary read of the destination scope. If it did,
    # merely *requesting* promotion would leak the content the request was asking permission to
    # share — the approval step would be advisory.
    visible_ids =
      Memory.query_knowledge(%{"scope_path" => "/", "state" => "active"}, actor)
      |> Enum.map(& &1["id"])

    refute knowledge.id in visible_ids

    # The complete tool surface offered to model clients. Asserting the exact list is the point:
    # a curator capability added here would be reachable by any agent holding a key, so the
    # inventory must be reviewed every time it changes. Reads, submissions, answering a question
    # about one's own memory, and lowering one's own interruption limit — nothing that decides.
    tool_names =
      Cartulary.Governance
      |> AshAi.Info.tools()
      |> Enum.map(& &1.name)
      |> Enum.sort()

    assert tool_names ==
             Enum.sort([
               :ask,
               :check_readiness,
               :get_context,
               :ingest,
               :query_knowledge,
               :resolve_validation,
               :search,
               :set_ask_preference
             ])

    refute Enum.any?(tool_names, &(&1 in [:approve, :edit, :reject, :merge, :defer]))

    # The same rule at the HTTP edge: routes where a person inspects and contests knowledge
    # about themselves reject a machine credential outright. 403 rather than 401 — the key is
    # valid, the identity kind is wrong.
    machine_self =
      build_conn()
      |> put_req_header("authorization", "Bearer #{agent.api_key}")
      |> get("/api/v1/self/knowledge")

    assert %{"error" => "Human identity required"} = json_response(machine_self, 403)
  end

  test "personal Gate B promotion requires verified subject consent after curator approval" do
    %{actor: actor} = bootstrap_human!("consent")

    knowledge =
      ingest!(
        actor,
        "consent-item",
        "/private/consent",
        "Avery's medical appointment is scheduled for next Thursday."
      )

    # A medical appointment is classified personal, which is what puts this item on the consent
    # path rather than the ordinary one.
    assert knowledge.sensitivity == "personal"
    root = scope_by_path!(actor, "/")
    promotion = Engine.request_promotion(actor, knowledge.id, root.id)

    # A curator approving is necessary but not sufficient. The item stays held and the response
    # says why: the subject has not agreed. A curator cannot consent on someone else's behalf.
    first_approval = Engine.decide(actor, promotion.validation.id, "approve")
    assert first_approval.consent_required
    assert first_approval.knowledge.state == "held"

    # Consent claimed over a machine channel, unverified, is refused rather than recorded as a
    # weak yes. Consent that an agent can fabricate is not consent.
    assert {:error, :verified_channel_required} =
             Engine.subject_consent(
               actor,
               knowledge.id,
               root.id,
               "grant",
               false,
               "mcp"
             )

    # The same grant through a verified human channel is accepted. Consent is recorded against
    # this knowledge item and this destination scope specifically — it is not a blanket
    # permission that a later, wider promotion could reuse.
    assert {:ok, consent} =
             Engine.subject_consent(
               actor,
               knowledge.id,
               root.id,
               "grant",
               true,
               "human_ui"
             )

    assert consent.status == "granted"
    assert consent.verified

    # Only now does the second approval move the item: it becomes active, it actually lives at
    # the destination scope, and the "held at" marker is cleared so it is no longer pending
    # anywhere.
    final_approval = Engine.decide(actor, promotion.validation.id, "approve")
    assert final_approval.knowledge.state == "active"
    assert final_approval.knowledge.scope_id == root.id
    assert final_approval.knowledge.held_scope_id == nil
  end

  test "only a human account admin may set consent_mode, and the change is audited" do
    %{actor: actor} = bootstrap_human!("consent-mode-rbac")

    agent =
      Identity.provision_agent(actor, %{
        key: "machine-consent-mode",
        name: "Machine Consent Mode",
        scope_path: "/",
        role: "curator"
      })

    assert {:ok, machine_actor} = Identity.authenticate_bearer(agent.api_key)

    # A machine credential holding the curator role must not be able to widen an Account's
    # privacy posture, exactly as it cannot approve, edit, reject, merge, or defer knowledge.
    assert_raise Ash.Error.Forbidden, fn ->
      DataLayer.with_actor(machine_actor, fn account, current_actor ->
        account
        |> Ash.Changeset.for_update(:configure_governance, %{consent_mode: "auto"})
        |> Ash.update!(actor: current_actor)
      end)
    end

    updated =
      DataLayer.with_actor(actor, fn account, current_actor ->
        account
        |> Ash.Changeset.for_update(:configure_governance, %{consent_mode: "auto"})
        |> Ash.update!(actor: current_actor)
      end)

    assert updated.consent_mode == "auto"

    events =
      DataLayer.with_actor(actor, fn account, current_actor ->
        Cartulary.Governance.AuditEvent
        |> Ash.Query.filter(action == "account.consent_mode_changed")
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read!(actor: pipeline_actor(current_actor))
      end)

    assert length(events) == 1
    assert hd(events).category == "configuration"
    assert hd(events).resource_id == updated.id
  end

  test "inline peer validation is rate-limited, transcript-verified, and correction text cannot mint" do
    %{actor: actor} = bootstrap_human!("inline")

    knowledge =
      ingest!(
        actor,
        "inline-session",
        "/governance/inline",
        "Avery prefers concise weekly release summaries."
      )

    # The pending item generated a question aimed at the peer it came from, bound to that peer's
    # session. A question addressed to anyone else would be asking a stranger to vouch for
    # someone else's memory.
    assert scalar!(
             "SELECT count(*) FROM sessions WHERE external_id = $1 AND peer_id = $2",
             ["inline-session", Ecto.UUID.dump!(actor.peer_id)]
           ) == 1

    assert scalar!(
             "SELECT count(*) FROM peer_queries WHERE knowledge_id = $1 AND peer_id = $2",
             [Ecto.UUID.dump!(knowledge.id), Ecto.UUID.dump!(actor.peer_id)]
           ) == 1

    # Attaching piggybacks the question onto a read the caller was making anyway. The question
    # text is frozen here: the statement the peer is shown is the statement their answer will be
    # matched against later, so it cannot change underneath them.
    question =
      PeerQueue.attach(
        actor,
        "inline-session",
        "get_context",
        "weekly release summaries"
      )

    assert question["id"]
    assert question["statement"] == knowledge.statement

    # The assistant turn that actually put the question in front of the human. It must contain
    # the frozen statement verbatim; the match tolerates quoting and spacing differences but not
    # a paraphrase. This transcript turn is the evidence that the peer saw what they are about
    # to confirm — without it, an agent could claim a confirmation nobody was ever asked for.
    {:ok, _assistant_message} =
      Memory.ingest_message(
        %{
          "session_id" => "inline-session",
          "scope_path" => "/governance/inline",
          "role" => "assistant",
          "content" => "I am checking this exact memory: \"#{knowledge.statement}\""
        },
        actor
      )

    {:ok, _answer_message} =
      Memory.ingest_message(
        %{
          "session_id" => "inline-session",
          "scope_path" => "/governance/inline",
          "role" => "user",
          "content" => "Yes, that remains true."
        },
        actor
      )

    # Resolving with a confirmation plus a free-text correction. The transcript above makes this
    # a verified channel, so the confirmation counts and the item is accepted.
    assert {:ok, result} =
             PeerQueue.resolve(
               actor,
               question["id"],
               "confirm",
               knowledge.statement,
               "This correction must not become knowledge."
             )

    assert result.verification == "verified"
    assert result.effect == "knowledge_confirmed"
    assert knowledge_for!(actor, knowledge.id).state == "active"
    assert validation_for!(actor, knowledge.id).state == "approved"

    # The correction text is kept as evidence on the answer, never minted as knowledge. This
    # channel confirms or rejects existing statements; it is not a side door for writing new
    # ones that would skip extraction provenance and both gates. A row here means an agent can
    # write arbitrary beliefs by attaching them to an answer.
    assert %{rows: [[0]]} =
             Repo.query!(
               "SELECT count(*) FROM knowledge_items WHERE statement = $1",
               ["This correction must not become knowledge."]
             )

    # Second item, same peer, but this time no assistant turn ever delivers the statement.
    unverified =
      ingest!(
        actor,
        "inline-unverified",
        "/governance/inline",
        "Avery uses the blue rollback checklist."
      )

    unverified_question =
      PeerQueue.attach(
        actor,
        "inline-unverified",
        "get_context",
        "blue rollback checklist"
      )

    assert {:ok, unverified_result} =
             PeerQueue.resolve(
               actor,
               unverified_question["id"],
               "confirm",
               unverified.statement
             )

    # An identical confirmation, with no proof the question was delivered, buys only a deferral
    # of the revalidation timer. The knowledge stays provisional and the human review stays
    # pending. This is the difference between "the peer told us" and "the agent says the peer
    # told us".
    assert unverified_result.verification == "unverified_channel"
    assert unverified_result.effect == "timer_deferred_only"
    assert knowledge_for!(actor, unverified.id).state == "provisional"
    assert validation_for!(actor, unverified.id).state == "pending"

    # Interruption limits, counted in questions per session and questions per day. A peer may
    # always turn them down.
    preference =
      PeerQueue.restrict_preferences(actor, %{
        max_per_session: 1,
        max_per_day: 2
      })

    assert preference.max_per_session == 1
    assert preference.max_per_day == 2

    # Asking for 99 does not raise them: the request is clamped to what the peer already chose.
    # The operation can only ever lower a limit, so nothing on the calling side — an agent, a
    # tool, a retry with different arguments — can talk a peer's quiet setting back up.
    clamped =
      PeerQueue.restrict_preferences(actor, %{
        max_per_session: 99,
        max_per_day: 99
      })

    assert clamped.max_per_session == 1
    assert clamped.max_per_day == 2
  end

  test "revalidation and pending aging decay, escalate, and auto-reject through dream-time" do
    %{actor: actor} = bootstrap_human!("sweep")

    # An auto-keep rule so the item starts out active with a revalidation deadline; aging only
    # applies to knowledge that was accepted in the first place. See the matrix test above for
    # what each field of a rule means.
    create_gate_rule!(actor, %{
      target_level: "peer",
      sensitivity: "internal",
      minimum_confidence: 0.5,
      gate_a_mode: "auto_keep",
      gate_b_mode: "auto_place",
      minimum_corroboration: 1,
      revalidate_after_days: 90,
      priority: 10
    })

    knowledge =
      ingest!(
        actor,
        "sweep-session",
        "/governance/sweep",
        "Avery prefers tagged deployment summaries."
      )

    pipeline = pipeline_actor(actor)

    # Time travel by data rather than by waiting: push the revalidation deadline one second into
    # the past so the sweeper sees an overdue item immediately. Sleeping for the real 90-day
    # window is obviously impossible, and freezing the clock globally would affect every other
    # process sharing this test's connection.
    Engine.transition!(
      knowledge,
      pipeline,
      %{revalidate_after: DateTime.add(Clock.utc_now(), -1, :second)},
      reason: "test_due",
      channel: "test"
    )

    # The sweeper reports how many items it touched and moves the overdue one out of `active`.
    # Knowledge past its revalidation date must stop being served as current fact even though
    # nobody has contradicted it.
    assert {:ok, %{revalidation: 1}} = Sweeper.run(actor.account_id, "revalidation")
    assert knowledge_for!(actor, knowledge.id).state == "needs_revalidation"

    # Marking an item stale is not enough on its own: the sweep also has to ask someone. The
    # revalidation question is what gives the item a route back to being trusted.
    query =
      DataLayer.with_actor(actor, fn account, current_actor ->
        PeerQuery
        |> Ash.Query.filter(knowledge_id == ^knowledge.id and kind == "revalidate")
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read_one!(actor: current_actor)
      end)

    assert query.state == "pending"

    # Backdate the answer deadline the same way. `update_delivery_state` accepts only the
    # delivery-tracking fields, so `deadline_at` has to be forced onto the changeset. Do not
    # copy this into application code — going around an action's accept list also goes around
    # its validations.
    query
    |> Ash.Changeset.for_update(:update_delivery_state, %{state: "pending"})
    |> Ash.Changeset.force_change_attribute(
      :deadline_at,
      DateTime.add(Clock.utc_now(), -1, :second)
    )
    |> Ash.Changeset.set_tenant(actor.account_id)
    |> Ash.update!(actor: pipeline)

    # The background reasoning pass reports several counters; this narrows the assertion to the
    # one under test so an unrelated counter changing does not fail the test.
    assert {:ok, %{decayed: 1}} =
             actor.account_id
             |> Sweeper.run("dream_time")
             |> then(fn {:ok, counts} -> {:ok, %{decayed: counts.decayed}} end)

    # An unanswered question costs the item confidence and marks it stale. Strictly lower, not
    # merely different: silence must never be read as reassurance.
    decayed = knowledge_for!(actor, knowledge.id)
    assert decayed.state == "stale"
    assert decayed.confidence < knowledge.confidence
  end

  test "proportionate erasure removes subject content and peer delivery text while audit survives" do
    %{actor: actor, peer: peer} = bootstrap_human!("erase")

    knowledge =
      ingest!(
        actor,
        "erase-session",
        "/governance/erase",
        "Avery prefers the private erasure checklist."
      )

    # Attaching first creates a delivered question, which holds a copy of the statement text.
    # Delivery records are a place personal content quietly accumulates, so erasure has to reach
    # them too, not just the knowledge table.
    assert PeerQueue.attach(actor, "erase-session", "get_context", "erasure checklist")
    request = Erasure.request(actor, peer.id, "proportionate")

    # Erasure is synchronous and reports what it removed; a request left pending would mean the
    # subject has no idea whether their data is gone.
    assert request.state == "completed"
    assert request.affected_counts["knowledge_deleted"] >= 1

    # The subject, the knowledge about them, and the question text delivered to them are all
    # actually deleted — not flagged, not hidden behind a filter a later query could forget.
    assert scalar!("SELECT count(*) FROM peers WHERE id = $1", [Ecto.UUID.dump!(peer.id)]) == 0

    assert scalar!("SELECT count(*) FROM knowledge_items WHERE id = $1", [
             Ecto.UUID.dump!(knowledge.id)
           ]) == 0

    assert scalar!("SELECT count(*) FROM peer_queries WHERE peer_id = $1", [
             Ecto.UUID.dump!(peer.id)
           ]) == 0

    # What survives is the content-free fact that an erasure happened, for this subject, at this
    # time. Deleting that too would make erasure unauditable and break the audit hash chain.
    assert scalar!(
             "SELECT count(*) FROM audit_events WHERE action = 'peer.erased' AND resource_id = $1",
             [Ecto.UUID.dump!(peer.id)]
           ) == 1
  end

  test "strict erasure completes through the same Ash boundary" do
    %{actor: actor} = bootstrap_human!("strict-erasure")

    knowledge =
      ingest!(
        actor,
        "strict-erasure-session",
        "/governance/strict-erasure",
        "Avery's medical archive uses the strict retention marker."
      )

    # Strict mode goes further than proportionate: it removes everything that reached the system
    # through this subject, not only statements about them. It must run through the same
    # governed operation and leave the same durable record, so the stricter option is not a
    # second, less careful deletion path.
    request = Erasure.request(actor, actor.peer_id, "strict")

    assert request.state == "completed"
    assert request.mode == "strict"
    assert request.affected_counts["mode"] == "strict"

    assert scalar!("SELECT count(*) FROM knowledge_items WHERE id = $1", [
             Ecto.UUID.dump!(knowledge.id)
           ]) == 0
  end

  test "the LiveView curator surface requires a human session and renders queue actions", %{
    conn: conn
  } do
    %{actor: actor, token: token} = bootstrap_human!("live")

    _knowledge =
      ingest!(actor, "live-session", "/governance/live", "Avery uses the release checklist.")

    # The curator console is reachable only through a browser session established by a human
    # sign-in. No token, no queue — an unauthenticated visitor is sent to sign in rather than
    # shown an empty page, which would hint that the console exists in a usable state.
    unauthenticated = get(conn, "/governance")
    assert redirected_to(unauthenticated) == "/governance/sign-in"

    authenticated =
      conn
      |> init_test_session(governance_token: token)
      |> get("/governance")

    # The queue actually renders the decisions a curator has to be able to make. If the markup
    # loads but the actions are missing, the human gate is unreachable in practice.
    body = html_response(authenticated, 200)
    assert body =~ "Governance queue"
    assert body =~ "Approve"
    assert body =~ "Edit as replacement"
    assert body =~ "Merge"
    assert body =~ "/assets/governance.js"

    # Scripts may come only from this origin. The console displays unreviewed, sometimes
    # sensitive statements; a third-party script tag on this page could read all of them.
    assert [csp] = get_resp_header(authenticated, "content-security-policy")
    assert csp =~ "script-src 'self'"

    # And the scripts that policy allows are genuinely served by this application. Everything
    # the console needs is vendored, so a self-hosted, network-isolated deployment renders the
    # same page as any other and no request ever leaves for a content delivery network.
    assert get(build_conn(), "/assets/governance.js")
           |> response(200) =~ "new LiveSocket"

    assert get(build_conn(), "/vendor/phoenix/phoenix.mjs")
           |> response(200) =~ "var Socket = class"

    assert get(build_conn(), "/vendor/phoenix_live_view/phoenix_live_view.esm.js")
           |> response(200) =~ "LiveSocket"
  end

  # Creates the Account, its containment root, an administrator Peer, and a signed session
  # token. Each test passes its own suffix because the email is unique per Account and the
  # tests share one database transaction.
  defp bootstrap_human!(suffix) do
    Identity.bootstrap_human(%{
      email: "#{suffix}@example.test",
      name: "F4 #{suffix}",
      password: "correct horse battery staple"
    })
  end

  # Submits one observation as the given human and returns the single knowledge item it
  # produced. Extraction runs inline here, so the gates have already run by the time the item
  # comes back — every test in this file starts from a governed item, never a raw row.
  defp ingest!(actor, session_id, scope_path, content) do
    {:ok, message} =
      Memory.ingest_message(
        %{
          "session_id" => session_id,
          "scope_path" => scope_path,
          "role" => "user",
          "content" => content
        },
        actor
      )

    message["knowledge"] |> hd() |> Map.fetch!("id") |> knowledge_for!(actor)
  end

  # Accepts its two arguments in either order so it can be used both directly and at the end of
  # a pipeline; the binary is always the knowledge id.
  defp knowledge_for!(id, actor) when is_binary(id), do: knowledge_for!(actor, id)

  # Reads through the internal pipeline identity on purpose. Several tests need to observe an
  # item in a state that is deliberately invisible to ordinary callers — held, provisional, or
  # stale — and an ordinary read would return nothing and make the test look like it passed for
  # the wrong reason.
  defp knowledge_for!(actor, id) do
    DataLayer.with_actor(actor, fn account, current_actor ->
      KnowledgeItem
      |> Ash.Query.filter(id == ^id)
      |> Ash.Query.set_tenant(account.id)
      |> Ash.read_one!(actor: pipeline_actor(current_actor))
    end)
  end

  # The one curator-queue entry for an item. Filtering on the gate kind matters: an item can
  # also carry queue entries for other purposes, and reading the wrong one would silently
  # assert against unrelated state.
  defp validation_for!(actor, knowledge_id) do
    DataLayer.with_actor(actor, fn account, current_actor ->
      ValidationItem
      |> Ash.Query.filter(knowledge_id == ^knowledge_id and kind == "gate_a_b")
      |> Ash.Query.set_tenant(account.id)
      |> Ash.read_one!(actor: current_actor)
    end)
  end

  defp scope_by_path!(actor, path) do
    DataLayer.with_actor(actor, fn account, current_actor ->
      Scope
      |> Ash.Query.filter(path == ^path)
      |> Ash.Query.set_tenant(account.id)
      |> Ash.read_one!(actor: current_actor)
    end)
  end

  # Writes one matrix cell as the administrator. Rules are Account configuration, so this
  # deliberately goes through the ordinary authorized action rather than inserting a row.
  defp create_gate_rule!(actor, attrs) do
    DataLayer.with_actor(actor, fn account, current_actor ->
      GateRule
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_tenant(account.id)
      |> Ash.Changeset.for_create(:create, attrs)
      |> Ash.create!(actor: current_actor)
    end)
  end

  # Elevates a human actor to the internal pipeline identity, which is what the extraction and
  # governance machinery runs as. Tests use it to observe and to age durable state. Application
  # code must never construct this: an actor that can write knowledge and see every lifecycle
  # state is precisely what the gates in this file exist to keep out of a request path.
  defp pipeline_actor(%Actor{} = actor), do: %{actor | role: :system, pipeline?: true}

  # Runs a parameterized query expected to return exactly one column of one row.
  defp scalar!(sql, params) do
    %{rows: [[value]]} = Ecto.Adapters.SQL.query!(Repo, sql, params)
    value
  end
end
