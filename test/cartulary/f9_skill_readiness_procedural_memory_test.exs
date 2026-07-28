# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.F9SkillReadinessProceduralMemoryTest do
  use CartularyWeb.ConnCase, async: false

  alias Cartulary.Actor
  alias Cartulary.Clock
  alias Cartulary.DataLayer
  alias Cartulary.Governance.Engine
  alias Cartulary.Identity
  alias Cartulary.Knowledge.KnowledgeItem
  alias Cartulary.Memory
  alias Cartulary.Skills
  alias Cartulary.Skills.Selector
  alias Cartulary.Skills.SkillRequirementCard

  require Ash.Query

  test "authored cards validate f9-1 selectors and inherit nearest requirement overrides" do
    seeded =
      seed_active!("inherit", "/f9/inherit", "Avery prefers concise release summaries.")

    assert {:error, message} =
             Skills.publish(seeded.actor, %{
               scope_path: "/",
               skill_key: "write-copy",
               requirements: [
                 %{
                   key: "invalid",
                   selector: %{unknown: "statement text"},
                   level: "required",
                   source_policy: "from-memory"
                 }
               ]
             })

    assert message =~ "unknown keys"

    assert {:ok, root_card} =
             Skills.publish(seeded.actor, %{
               scope_path: "/",
               skill_key: "write-copy",
               description: "Base copy requirements",
               requirements: [
                 requirement("voice", "preference", "required", "from-memory"),
                 requirement("background", "fact", "preferred", "either")
               ]
             })

    assert root_card.version == 1
    assert root_card.requirement_schema_version == Selector.schema_version()

    assert {:ok, child_card} =
             Skills.publish(seeded.actor, %{
               scope_path: "/f9/inherit",
               skill_key: "write-copy",
               description: "Team override",
               requirements: [
                 requirement("voice", "preference", "required", "either"),
                 requirement("background", "fact", "preferred", "either", enabled: false),
                 requirement("deadline", "event", "preferred", "ask-peer")
               ]
             })

    assert child_card.version == 1

    report =
      Skills.check_readiness(seeded.actor, %{
        skill: "write-copy",
        scope_path: "/f9/inherit"
      })

    assert report["ready"]
    assert Enum.map(report["requirements"], & &1["key"]) == ["voice", "deadline"]

    voice = Enum.find(report["requirements"], &(&1["key"] == "voice"))
    assert voice["status"] == "satisfied"
    assert voice["source_policy"] == "either"
    assert voice["source_scope_path"] == "/f9/inherit"
    assert voice["matched_knowledge_ids"] == [seeded.knowledge.id]

    assert [%{"key" => "deadline", "level" => "preferred", "status" => "missing"}] =
             report["warnings"]

    assert {:ok, version_two} =
             Skills.publish(seeded.actor, %{
               scope_path: "/f9/inherit",
               skill_key: "write-copy",
               requirements: [
                 requirement("voice", "preference", "required", "either")
               ]
             })

    assert version_two.version == 2

    DataLayer.with_actor(seeded.actor, fn account, actor ->
      scope_id = seeded.scope.id

      cards =
        SkillRequirementCard
        |> Ash.Query.filter(scope_id == ^scope_id and skill_key == "write-copy")
        |> Ash.Query.sort(version: :asc)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read!(actor: actor)

      assert Enum.map(cards, &{&1.version, &1.active}) == [{1, false}, {2, true}]
    end)

    assert scalar!(
             """
             SELECT count(*) FROM audit_events
             WHERE resource_type = 'skill_requirement_card'
             """,
             []
           ) == 4
  end

  test "required gaps block while preferred gaps only warn and emit elicitation plans" do
    seeded = seed_active!("gaps", "/f9/gaps", "Avery prefers concise release summaries.")

    assert {:ok, _card} =
             Skills.publish(seeded.actor, %{
               scope_path: "/f9/gaps",
               skill_key: "ship-release",
               requirements: [
                 requirement("voice", "preference", "required", "from-memory"),
                 requirement("context", "fact", "preferred", "either")
               ]
             })

    warning_only =
      Skills.check_readiness(seeded.actor, %{
        skill: "ship-release",
        scope_path: "/f9/gaps"
      })

    assert warning_only["ready"]
    refute warning_only["blocked"]
    assert warning_only["blockers"] == []

    assert [
             %{
               "key" => "context",
               "blocking" => false,
               "elicitation" => %{
                 "allowed" => true,
                 "submit_via" => "ingest",
                 "then" => "check_readiness"
               }
             }
           ] = warning_only["warnings"]

    assert {:ok, _card} =
             Skills.publish(seeded.actor, %{
               scope_path: "/f9/gaps",
               skill_key: "ship-release",
               requirements: [
                 requirement("voice", "preference", "required", "from-memory"),
                 requirement("approval-window", "event", "required", "ask-peer"),
                 requirement("context", "fact", "preferred", "either")
               ]
             })

    blocked =
      Skills.check_readiness(seeded.actor, %{
        skill: "ship-release",
        scope_path: "/f9/gaps"
      })

    refute blocked["ready"]
    assert blocked["blocked"]

    assert [
             %{
               "key" => "approval-window",
               "blocking" => true,
               "status" => "missing",
               "elicitation" => %{"allowed" => true}
             }
           ] = blocked["blockers"]

    assert Enum.map(blocked["warnings"], & &1["key"]) == ["context"]
  end

  test "expired, due, and needs_revalidation knowledge never satisfies readiness" do
    seeded =
      seed_active!(
        "stale",
        "/f9/stale",
        "Avery prefers concise release summaries.",
        revalidate_after: DateTime.add(Clock.utc_now(), -1, :second)
      )

    assert {:ok, _card} =
             Skills.publish(seeded.actor, %{
               scope_path: "/f9/stale",
               skill_key: "write-copy",
               requirements: [
                 requirement("voice", "preference", "required", "from-memory")
               ]
             })

    due =
      Skills.check_readiness(seeded.actor, %{
        skill: "write-copy",
        scope_path: "/f9/stale"
      })

    assert [%{"key" => "voice", "status" => "stale"}] = due["blockers"]
    assert hd(due["blockers"])["stale_knowledge_ids"] == [seeded.knowledge.id]

    transition!(seeded, "needs_revalidation", revalidate_after: nil)

    revalidation =
      Skills.check_readiness(seeded.actor, %{
        skill: "write-copy",
        scope_path: "/f9/stale"
      })

    assert [%{"status" => "stale"}] = revalidation["blockers"]

    transition!(seeded, "expired", expires_at: DateTime.add(Clock.utc_now(), -1, :second))

    expired =
      Skills.check_readiness(seeded.actor, %{
        skill: "write-copy",
        scope_path: "/f9/stale"
      })

    assert [%{"status" => "stale"}] = expired["blockers"]
  end

  test "HTTP, MCP metadata, governance UI, and SDK helpers expose the same f9-1 contract", %{
    conn: conn
  } do
    seeded =
      seed_active!("surfaces", "/f9/surfaces", "Avery prefers concise release summaries.")

    assert {:ok, _card} =
             Skills.publish(seeded.actor, %{
               scope_path: "/f9/surfaces",
               skill_key: "write-copy",
               requirements: [
                 requirement("voice", "preference", "required", "ask-peer")
               ]
             })

    response =
      conn
      |> put_req_header("authorization", "Bearer #{seeded.token}")
      |> post("/api/v1/readiness", %{
        "skill" => "write-copy",
        "scope_path" => "/f9/surfaces"
      })

    assert %{
             "data" => %{
               "report_version" => "f9-1",
               "ready" => true,
               "requirements" => [%{"status" => "satisfied"}]
             }
           } = json_response(response, 200)

    tool_names =
      Cartulary.Governance
      |> AshAi.Info.tools()
      |> Enum.map(& &1.name)

    assert :check_readiness in tool_names

    page =
      build_conn()
      |> init_test_session(governance_token: seeded.token)
      |> get("/governance")
      |> html_response(200)

    assert page =~ "Skill requirement cards"
    assert page =~ "write-copy"
    assert page =~ "f9-1"

    assert File.read!("sdk/typescript/src/skill-readiness.ts") =~
             "SkillReadinessBlockedError"

    assert File.read!("sdk/python/cartulary/skill_readiness.py") =~
             "SkillReadinessBlockedError"
  end

  defp seed_active!(suffix, scope_path, content, attrs \\ []) do
    bootstrap =
      Identity.bootstrap_human(%{
        email: "f9-#{suffix}@example.test",
        name: "F9 #{suffix}",
        password: "correct horse battery staple"
      })

    assert {:ok, message} =
             Memory.ingest_message(
               %{
                 "session_id" => "f9-#{suffix}",
                 "scope_path" => scope_path,
                 "role" => "user",
                 "content" => content
               },
               bootstrap.actor
             )

    knowledge_id = message["knowledge"] |> hd() |> Map.fetch!("id")

    {scope, knowledge} =
      DataLayer.with_actor(bootstrap.actor, fn account, actor ->
        scope =
          Cartulary.Topology.Scope
          |> Ash.Query.filter(path == ^scope_path)
          |> Ash.Query.set_tenant(account.id)
          |> Ash.read_one!(actor: pipeline_actor(actor))

        knowledge =
          KnowledgeItem
          |> Ash.Query.filter(id == ^knowledge_id)
          |> Ash.Query.set_tenant(account.id)
          |> Ash.read_one!(actor: pipeline_actor(actor))

        knowledge =
          Engine.transition!(
            knowledge,
            pipeline_actor(actor),
            attrs
            |> Map.new()
            |> Map.put(:state, "active")
            |> Map.put(:verification, "peer_verified"),
            reason: "f9_test_activate",
            channel: "pipeline"
          )

        {scope, knowledge}
      end)

    assert {:ok, refreshed_actor} = Identity.authenticate_bearer(bootstrap.token)

    bootstrap
    |> Map.put(:actor, refreshed_actor)
    |> Map.merge(%{scope: scope, knowledge: knowledge})
  end

  defp transition!(seeded, state, attrs) do
    DataLayer.with_actor(seeded.actor, fn _account, actor ->
      knowledge =
        KnowledgeItem
        |> Ash.Query.filter(id == ^seeded.knowledge.id)
        |> Ash.Query.set_tenant(actor.account_id)
        |> Ash.read_one!(actor: pipeline_actor(actor))

      Engine.transition!(
        knowledge,
        pipeline_actor(actor),
        attrs |> Map.new() |> Map.put(:state, state),
        reason: "f9_test_#{state}",
        channel: "pipeline"
      )
    end)
  end

  defp requirement(key, kind, level, source_policy, opts \\ []) do
    %{
      key: key,
      description: "#{key} requirement",
      selector: %{kind: kind, subject: "peer"},
      level: level,
      source_policy: source_policy,
      prompt: "Please provide #{key}.",
      enabled: Keyword.get(opts, :enabled, true)
    }
  end

  defp pipeline_actor(%Actor{} = actor),
    do: %{actor | role: :system, pipeline?: true, scope_ids: :all}

  defp scalar!(sql, params) do
    %{rows: [[value]]} = Ecto.Adapters.SQL.query!(Cartulary.Repo, sql, params)
    value
  end
end
