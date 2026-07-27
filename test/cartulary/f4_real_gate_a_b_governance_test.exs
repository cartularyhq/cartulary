# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.F4RealGateABGovernanceTest do
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

    assert validation.state == "pending"

    assert Enum.map(decisions, &{&1.gate, &1.decision}) == [
             {"gate_a", "defer"},
             {"gate_b", "provisional"}
           ]

    history = Engine.history(actor, first.id)

    assert Enum.map(history.lifecycle, & &1.to_state) == ["proposed", "provisional"]

    assert Enum.map(history.gate_decisions, &{&1.gate, &1.decision}) ==
             Enum.map(decisions, &{&1.gate, &1.decision})

    assert scalar!(
             """
             SELECT count(*) FROM audit_events
             WHERE resource_id = $1
               AND action IN ('knowledge.created', 'knowledge.transitioned')
             """,
             [Ecto.UUID.dump!(first.id)]
           ) == 2

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

    assert {:ok, machine_actor} = Identity.authenticate_bearer(agent.api_key)
    assert machine_actor.role == :curator
    assert machine_actor.identity_kind == :api_key

    assert_raise Ash.Error.Forbidden, fn ->
      Engine.decide(machine_actor, validation.id, "approve")
    end

    root = scope_by_path!(actor, "/")
    promotion = Engine.request_promotion(actor, knowledge.id, root.id)
    assert promotion.knowledge.state == "held"

    visible_ids =
      Memory.query_knowledge(%{"scope_path" => "/", "state" => "active"}, actor)
      |> Enum.map(& &1["id"])

    refute knowledge.id in visible_ids

    tool_names =
      Cartulary.Governance
      |> AshAi.Info.tools()
      |> Enum.map(& &1.name)
      |> Enum.sort()

    assert tool_names ==
             Enum.sort([
               :ask,
               :get_context,
               :ingest,
               :query_knowledge,
               :resolve_validation,
               :search,
               :set_ask_preference
             ])

    refute Enum.any?(tool_names, &(&1 in [:approve, :edit, :reject, :merge, :defer]))

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

    assert knowledge.sensitivity == "personal"
    root = scope_by_path!(actor, "/")
    promotion = Engine.request_promotion(actor, knowledge.id, root.id)

    first_approval = Engine.decide(actor, promotion.validation.id, "approve")
    assert first_approval.consent_required
    assert first_approval.knowledge.state == "held"

    assert {:error, :verified_channel_required} =
             Engine.subject_consent(
               actor,
               knowledge.id,
               root.id,
               "grant",
               false,
               "mcp"
             )

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

    final_approval = Engine.decide(actor, promotion.validation.id, "approve")
    assert final_approval.knowledge.state == "active"
    assert final_approval.knowledge.scope_id == root.id
    assert final_approval.knowledge.held_scope_id == nil
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

    assert scalar!(
             "SELECT count(*) FROM sessions WHERE external_id = $1 AND peer_id = $2",
             ["inline-session", Ecto.UUID.dump!(actor.peer_id)]
           ) == 1

    assert scalar!(
             "SELECT count(*) FROM peer_queries WHERE knowledge_id = $1 AND peer_id = $2",
             [Ecto.UUID.dump!(knowledge.id), Ecto.UUID.dump!(actor.peer_id)]
           ) == 1

    question =
      PeerQueue.attach(
        actor,
        "inline-session",
        "get_context",
        "weekly release summaries"
      )

    assert question["id"]
    assert question["statement"] == knowledge.statement

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

    assert %{rows: [[0]]} =
             Repo.query!(
               "SELECT count(*) FROM knowledge_items WHERE statement = $1",
               ["This correction must not become knowledge."]
             )

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

    assert unverified_result.verification == "unverified_channel"
    assert unverified_result.effect == "timer_deferred_only"
    assert knowledge_for!(actor, unverified.id).state == "provisional"
    assert validation_for!(actor, unverified.id).state == "pending"

    preference =
      PeerQueue.restrict_preferences(actor, %{
        max_per_session: 1,
        max_per_day: 2
      })

    assert preference.max_per_session == 1
    assert preference.max_per_day == 2

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

    Engine.transition!(
      knowledge,
      pipeline,
      %{revalidate_after: DateTime.add(Clock.utc_now(), -1, :second)},
      reason: "test_due",
      channel: "test"
    )

    assert {:ok, %{revalidation: 1}} = Sweeper.run(actor.account_id, "revalidation")
    assert knowledge_for!(actor, knowledge.id).state == "needs_revalidation"

    query =
      DataLayer.with_actor(actor, fn account, current_actor ->
        PeerQuery
        |> Ash.Query.filter(knowledge_id == ^knowledge.id and kind == "revalidate")
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read_one!(actor: current_actor)
      end)

    assert query.state == "pending"

    query
    |> Ash.Changeset.for_update(:update_delivery_state, %{state: "pending"})
    |> Ash.Changeset.force_change_attribute(
      :deadline_at,
      DateTime.add(Clock.utc_now(), -1, :second)
    )
    |> Ash.Changeset.set_tenant(actor.account_id)
    |> Ash.update!(actor: pipeline)

    assert {:ok, %{decayed: 1}} =
             actor.account_id
             |> Sweeper.run("dream_time")
             |> then(fn {:ok, counts} -> {:ok, %{decayed: counts.decayed}} end)

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

    assert PeerQueue.attach(actor, "erase-session", "get_context", "erasure checklist")
    request = Erasure.request(actor, peer.id, "proportionate")

    assert request.state == "completed"
    assert request.affected_counts["knowledge_deleted"] >= 1

    assert scalar!("SELECT count(*) FROM peers WHERE id = $1", [Ecto.UUID.dump!(peer.id)]) == 0

    assert scalar!("SELECT count(*) FROM knowledge_items WHERE id = $1", [
             Ecto.UUID.dump!(knowledge.id)
           ]) == 0

    assert scalar!("SELECT count(*) FROM peer_queries WHERE peer_id = $1", [
             Ecto.UUID.dump!(peer.id)
           ]) == 0

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

    unauthenticated = get(conn, "/governance")
    assert redirected_to(unauthenticated) == "/governance/sign-in"

    authenticated =
      conn
      |> init_test_session(governance_token: token)
      |> get("/governance")

    body = html_response(authenticated, 200)
    assert body =~ "Governance queue"
    assert body =~ "Approve"
    assert body =~ "Edit as replacement"
    assert body =~ "Merge"
    assert body =~ "/assets/governance.js"

    assert [csp] = get_resp_header(authenticated, "content-security-policy")
    assert csp =~ "script-src 'self'"

    assert get(build_conn(), "/assets/governance.js")
           |> response(200) =~ "new LiveSocket"

    assert get(build_conn(), "/vendor/phoenix/phoenix.mjs")
           |> response(200) =~ "var Socket = class"

    assert get(build_conn(), "/vendor/phoenix_live_view/phoenix_live_view.esm.js")
           |> response(200) =~ "LiveSocket"
  end

  defp bootstrap_human!(suffix) do
    Identity.bootstrap_human(%{
      email: "#{suffix}@example.test",
      name: "F4 #{suffix}",
      password: "correct horse battery staple"
    })
  end

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

  defp knowledge_for!(id, actor) when is_binary(id), do: knowledge_for!(actor, id)

  defp knowledge_for!(actor, id) do
    DataLayer.with_actor(actor, fn account, current_actor ->
      KnowledgeItem
      |> Ash.Query.filter(id == ^id)
      |> Ash.Query.set_tenant(account.id)
      |> Ash.read_one!(actor: pipeline_actor(current_actor))
    end)
  end

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

  defp create_gate_rule!(actor, attrs) do
    DataLayer.with_actor(actor, fn account, current_actor ->
      GateRule
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_tenant(account.id)
      |> Ash.Changeset.for_create(:create, attrs)
      |> Ash.create!(actor: current_actor)
    end)
  end

  defp pipeline_actor(%Actor{} = actor), do: %{actor | role: :system, pipeline?: true}

  defp scalar!(sql, params) do
    %{rows: [[value]]} = Ecto.Adapters.SQL.query!(Repo, sql, params)
    value
  end
end
