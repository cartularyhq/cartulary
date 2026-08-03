# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.ConsoleLiveTest do
  @moduledoc """
  End-to-end evidence for the browser console: who may open it, what each role is
    shown, and that the pages render against a real Account rather than a fixture.

    1. **An unauthenticated or machine caller reaching the console.
  """

  use CartularyWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Cartulary.Accounts.ExternalIdentity
  alias Cartulary.Accounts.Peer
  alias Cartulary.Actor
  alias Cartulary.Clock
  alias Cartulary.DataLayer
  alias Cartulary.Governance.Engine, as: GovernanceEngine
  alias Cartulary.Identity
  alias Cartulary.Knowledge.Entity
  alias Cartulary.Knowledge.EntityMention
  alias Cartulary.Knowledge.KnowledgeItem
  alias Cartulary.Memory
  alias CartularyWeb.Console.Loader

  require Ash.Query

  @password "correct horse battery staple"

  describe "reaching the console" do
    test "an anonymous visitor is sent to sign in", %{conn: conn} do
      assert redirected_to(get(conn, "/console")) == "/sign-in"
      assert redirected_to(get(conn, "/console/knowledge")) == "/sign-in"
      assert redirected_to(get(conn, "/console/tools")) == "/sign-in"
      assert redirected_to(get(conn, "/console/me")) == "/sign-in"
    end

    test "the bare origin points at the console", %{conn: conn} do
      assert redirected_to(get(conn, "/")) == "/console"
    end

    test "a machine credential cannot open a console session", %{conn: conn} do
      %{actor: admin} = bootstrap_admin!()

      %{api_key: api_key} =
        Identity.provision_agent(admin, %{"key" => "console-agent", "scope_path" => "/"})

      # An API key is a valid credential on the JSON surface. It is not a person,
      # so the browser surface must refuse it rather than resolve it.
      conn = conn |> init_test_session(governance_token: api_key) |> get("/console")

      assert redirected_to(conn) == "/sign-in"
    end

    test "sign-in rejects a wrong password without saying why", %{conn: conn} do
      bootstrap_admin!()

      conn = post(conn, "/sign-in", %{"email" => "admin@example.test", "password" => "wrong"})

      assert redirected_to(conn) == "/sign-in?error=invalid"
    end

    test "a correct sign-in opens the console", %{conn: conn} do
      bootstrap_admin!()

      conn = post(conn, "/sign-in", %{"email" => "admin@example.test", "password" => @password})

      assert redirected_to(conn) == "/console"
      assert get_session(conn, :governance_token)
    end
  end

  describe "the pages an account admin sees" do
    setup [:seed_world]

    test "the overview counts what is stored and offers the operator tiles", %{
      conn: conn,
      admin_token: token
    } do
      html = conn |> sign_in(token) |> get("/console") |> html_response(200)

      assert html =~ "Overview"
      assert html =~ "Statements you can read"
      assert html =~ "Lifecycle"
      # Operator tiles are for account admins only.
      assert html =~ "System readiness"
      assert html =~ "Recorded usage"
      assert html =~ "Operations"
    end

    test "the explorer lists the ingested statement", %{
      conn: conn,
      admin_token: token,
      statement: statement
    } do
      html = conn |> sign_in(token) |> get("/console/knowledge") |> html_response(200)

      assert html =~ "Knowledge"
      assert html =~ statement
    end

    test "the detail page shows provenance, lifecycle, and the raw observation", %{
      conn: conn,
      admin_token: token,
      knowledge_id: id,
      statement: statement,
      observation: observation
    } do
      html = conn |> sign_in(token) |> get("/console/knowledge/#{id}") |> html_response(200)

      assert html =~ statement
      assert html =~ "Provenance"
      assert html =~ "Lifecycle"
      assert html =~ "How this was produced"
      # The raw observation is the whole point of the page: a reader must be
      # able to check the claim against what was actually said.
      assert html =~ observation
    end

    test "an unknown statement id reports not found rather than forbidden", %{
      conn: conn,
      admin_token: token
    } do
      html =
        conn
        |> sign_in(token)
        |> get("/console/knowledge/#{Ecto.UUID.generate()}")
        |> html_response(200)

      assert html =~ "Statement not found"
    end

    test "the scope directory shows the tree and the grants behind it", %{
      conn: conn,
      admin_token: token
    } do
      html = conn |> sign_in(token) |> get("/console/scopes") |> html_response(200)

      assert html =~ "Directory"
      assert html =~ "/console-test"
      assert html =~ "Role grants"
    end

    test "the scope directory shows index coverage for a scope whose refresh never ran", %{
      conn: conn,
      admin_token: token
    } do
      html = conn |> sign_in(token) |> get("/console/scopes") |> html_response(200)

      # The world is seeded by ingestion alone, so its statements exist and its vectors do
      # not — the state a cancelled projection refresh leaves behind. Without this column the
      # page is identical to a fully indexed Account.
      assert html =~ "Indexed"
      assert html =~ "Mentions"
      assert html =~ "coverage-gap"
    end

    test "the graph renders SVG nodes and no entity data", %{conn: conn, admin_token: token} do
      html = conn |> sign_in(token) |> get("/console/graph") |> html_response(200)

      assert html =~ "<svg"
      assert html =~ "node-scope"
      # The recall cache must not surface here under any name.
      refute html =~ "canonical_name"
      refute html =~ "entity_mention"
    end

    test "sources shows the raw observation it was extracted from", %{
      conn: conn,
      admin_token: token,
      observation: observation
    } do
      html = conn |> sign_in(token) |> get("/console/sources") |> html_response(200)

      assert html =~ "Observations"
      assert html =~ observation
    end

    test "skills offers a readiness check and the card library", %{
      conn: conn,
      admin_token: token
    } do
      html = conn |> sign_in(token) |> get("/console/skills") |> html_response(200)

      assert html =~ "Check your readiness"
      assert html =~ "Card library"
    end

    test "the tool workbench exposes and runs the complete MCP action inventory", %{
      conn: conn,
      admin_token: token,
      statement: statement
    } do
      {:ok, view, html} = live(sign_in(conn, token), "/console/tools")

      for tool <-
            ~w(ingest get_context search ask query_knowledge check_readiness resolve_validation set_ask_preference) do
        assert html =~ ~s|id="tool-#{tool}"|
      end

      html =
        render_submit(view, "run", %{
          "tool" => "query_knowledge",
          "session_id" => "console-tools-query",
          "scope_path" => "/console-test",
          "state" => "active",
          "limit" => "5"
        })

      assert html =~ "Result · query_knowledge"
      assert html =~ statement

      html =
        render_submit(view, "run", %{
          "tool" => "search",
          "session_id" => "console-tools-search",
          "scope_path" => "/console-test",
          "query" => "asynchronous standups",
          "profile" => "balanced",
          "limit" => "5"
        })

      assert html =~ "Result · search"
      assert html =~ ~s|&quot;profile&quot;: &quot;balanced&quot;|
      assert html =~ ~s|&quot;candidates&quot;|
      assert html =~ ~s|&quot;retrieval_outcomes&quot;|

      html =
        render_submit(view, "run", %{
          "tool" => "ingest",
          "session_id" => "console-tools-ingest",
          "scope_path" => "/console-test",
          "role" => "user",
          "content" => "Avery writes release notes on Fridays."
        })

      assert html =~ "Result · ingest"
      assert html =~ ~s|&quot;status&quot;: &quot;accepted&quot;|

      html =
        render_submit(view, "run", %{
          "tool" => "set_ask_preference",
          "max_per_session" => "1"
        })

      assert html =~ "Result · set_ask_preference"
      assert html =~ ~s|&quot;max_per_session&quot;: 1|

      html =
        render_submit(view, "run", %{
          "tool" => "resolve_validation",
          "_id" => Ecto.UUID.generate(),
          "verdict" => "skip"
        })

      assert html =~ "Tool call failed. Check the fields and your access"
      refute html =~ "Result · resolve_validation"
    end

    test "the personal page offers the subject gestures", %{conn: conn, admin_token: token} do
      html = conn |> sign_in(token) |> get("/console/me") |> html_response(200)

      assert html =~ "About me"
      assert html =~ "Consent requests"
      assert html =~ "Erasure"
    end

    test "operations reports content-free entity resolution quality signals", %{
      conn: conn,
      admin: admin,
      admin_token: token,
      knowledge_id: knowledge_id
    } do
      seed_resolution_metrics!(admin, knowledge_id)

      Cartulary.Retrieval.Diagnostics.record(
        admin.account_id,
        %{
          profile: "thorough",
          profile_version: "f7-1",
          latency_ms: 750,
          pre_rerank_remaining_ms: 600,
          retrieval_outcomes: [
            %{
              component: "reranker",
              status: "dropped",
              reason_class: "timeout",
              elapsed_ms: 500,
              budget_remaining_ms: 100
            }
          ]
        },
        1_500
      )

      metrics = Loader.operations(admin).entity_resolution

      assert metrics.entity_count == 2
      assert metrics.mention_count == 3
      assert metrics.singleton_entity_rate == 0.5
      assert metrics.mentions_per_entity_p50 == 1
      assert metrics.mentions_per_entity_p95 == 2
      assert %{range: "1", entity_count: 1} in metrics.aliases_per_entity
      assert %{range: "2–3", entity_count: 1} in metrics.aliases_per_entity

      html = conn |> sign_in(token) |> get("/console/operations") |> html_response(200)

      assert html =~ "Readiness"
      assert html =~ "Entity resolution quality"
      assert html =~ "Singleton entity rate"
      assert html =~ "50.0%"
      assert html =~ "Gate matrix"
      assert html =~ "Retrieval tunings"
      assert html =~ "Latest retrieval outcome"
      assert html =~ ~s|id="retrieval-outcomes"|
      assert html =~ "reranker"
      assert html =~ "timeout"
      refute html =~ "SecretNeedle104"
      refute html =~ "NeverRenderAlias71"
    end
  end

  describe "what a member is not shown" do
    setup [:seed_world]

    test "no governance queue link and no operations link", %{conn: conn, member_token: token} do
      html = conn |> sign_in(token) |> get("/console") |> html_response(200)

      assert html =~ "Overview"
      refute html =~ "Governance queue"
      refute html =~ "System readiness"
      refute html =~ ~s|href="/console/operations"|
    end

    test "the operations page declines rather than crashing", %{conn: conn, member_token: token} do
      # The resources behind this page refuse a lesser role outright, so an
      # ungated render would raise. The redirect is the evidence that the gate
      # runs before the first query.
      assert redirected_to(conn |> sign_in(token) |> get("/console/operations")) == "/console"

      assert {:ok, member} = Identity.authenticate_bearer(token)
      assert_raise Ash.Error.Forbidden, fn -> Loader.operations(member) end
    end

    test "the explorer offers no undecided lifecycle state as a filter", %{
      conn: conn,
      member_token: token
    } do
      html = conn |> sign_in(token) |> get("/console/knowledge") |> html_response(200)

      assert html =~ ~s|value="active"|
      refute html =~ ~s|value="proposed"|
      refute html =~ ~s|value="held"|
    end

    test "a scope the member holds no grant on is absent, not empty", %{
      conn: conn,
      member_token: token,
      statement: statement
    } do
      # The member in this world holds a role only on the root scope, with no
      # propagation, so `/console-test` is out of reach entirely. It must not
      # appear in the directory as an empty row: absent and empty are
      # deliberately indistinguishable from outside, and rendering the path
      # would disclose that the scope exists at all.
      directory = conn |> sign_in(token) |> get("/console/scopes") |> html_response(200)

      assert directory =~ "Directory"
      refute directory =~ "/console-test"

      explorer = conn |> sign_in(token) |> get("/console/knowledge") |> html_response(200)

      refute explorer =~ statement

      workbench = conn |> sign_in(token) |> get("/console/tools") |> html_response(200)

      assert workbench =~ "Tool workbench"
      refute workbench =~ "/console-test"
    end

    test "co-mention neighbors include only readable scopes", %{
      conn: conn,
      admin: admin,
      member_id: member_id,
      member_token: member_token,
      knowledge_id: knowledge_id
    } do
      readable =
        ingest_statement!(
          admin,
          "console-shared-readable",
          "/console-test",
          "The release owner publishes the weekly checklist."
        )

      hidden =
        ingest_statement!(
          admin,
          "console-shared-hidden",
          "/console-hidden",
          "The private review also names the release owner."
        )

      activate_knowledge!(admin, [knowledge_id, readable.id, hidden.id])
      link_shared_entity!(admin, [knowledge_id, readable.id, hidden.id])
      admin = Identity.refresh_actor(admin)

      Identity.grant_role(admin, %{
        "scope_path" => "/console-test",
        "peer_id" => member_id,
        "role" => "reader",
        "propagate" => false
      })

      assert {:ok, member} = Identity.authenticate_bearer(member_token)
      detail = Loader.knowledge_detail(member, knowledge_id)

      assert detail.co_mentions_count == 1
      refute detail.co_mentions_truncated?
      assert Enum.map(detail.co_mentions, & &1.id) == [readable.id]

      html =
        conn
        |> sign_in(member_token)
        |> get("/console/knowledge/#{knowledge_id}")
        |> html_response(200)

      assert html =~ "Shared-entity neighbors"
      assert html =~ "Other statements"
      assert html =~ readable.statement
      refute html =~ hidden.statement
      refute html =~ "NeverRenderSharedEntity71"
    end
  end

  # ----------------------------------------------------------------------------
  # World
  # ----------------------------------------------------------------------------

  # One Account holding a real administrator, a real member, one ingested
  # observation, and the statement extracted from it. Everything is created
  # through the ordinary paths — bootstrap, ingest, role grant — so the test
  # exercises the same code a running deployment does.
  defp seed_world(%{conn: _conn} = context) do
    %{actor: admin, token: admin_token} = bootstrap_admin!()

    observation = "Avery prefers asynchronous standups."

    {:ok, message} =
      Memory.ingest_message(
        %{
          "session_id" => "console-session",
          "scope_path" => "/console-test",
          "role" => "user",
          "content" => observation
        },
        admin
      )

    {:ok, [knowledge]} =
      Memory.extract_message_for_account(message["id"], admin.account_id)

    %{id: member_id, token: member_token} = create_member!(admin)

    Map.merge(context, %{
      admin: admin,
      admin_token: admin_token,
      member_id: member_id,
      member_token: member_token,
      observation: observation,
      knowledge_id: Map.fetch!(knowledge, "id"),
      statement: Map.fetch!(knowledge, "statement")
    })
  end

  defp bootstrap_admin! do
    Identity.bootstrap_human(%{
      email: "admin@example.test",
      name: "Console Admin",
      password: @password
    })
  end

  # Registers a second person with a password credential and grants them the
  # member role at the root without propagation, then signs them in and returns
  # their token.
  #
  # A non-propagating grant is what makes this peer a useful test subject: they
  # can open the console, and they can reach nothing inside `/console-test`. A
  # propagating grant would hide the difference between "no access" and "no
  # rows".
  defp create_member!(admin) do
    peer_id =
      DataLayer.with_actor(admin, fn account, actor ->
        peer =
          Peer
          |> Ash.Changeset.new()
          |> Ash.Changeset.set_tenant(account.id)
          |> Ash.Changeset.for_create(:register_with_password, %{
            key: "console-member",
            name: "Console Member",
            kind: "human",
            email: "member@example.test",
            password: @password,
            password_confirmation: @password
          })
          |> Ash.create!(actor: Actor.for_account(account, role: :system))

        ExternalIdentity
        |> Ash.Changeset.new()
        |> Ash.Changeset.set_tenant(account.id)
        |> Ash.Changeset.for_create(:create, %{
          peer_id: peer.id,
          provider: "password",
          subject: "member@example.test",
          email: "member@example.test",
          assurance: "medium",
          linked_at: Clock.utc_now(),
          active: true
        })
        |> Ash.create!(actor: actor)

        peer.id
      end)

    Identity.grant_role(admin, %{
      "scope_path" => "/",
      "peer_id" => peer_id,
      "role" => "member",
      "propagate" => false
    })

    {:ok, %{token: token}} = Identity.sign_in_password("member@example.test", @password)
    %{id: peer_id, token: token}
  end

  defp seed_resolution_metrics!(admin, knowledge_id) do
    DataLayer.with_actor(admin, fn account, actor ->
      pipeline = pipeline_actor(actor)

      first =
        create!(
          Entity,
          :create_from_pipeline,
          %{
            canonical_name: "NeverRenderAlias71",
            kind: "person",
            aliases: ["NeverRenderAlias71", "NRA71"],
            derived_from: [knowledge_id]
          },
          account.id,
          pipeline
        )

      second =
        create!(
          Entity,
          :create_from_pipeline,
          %{
            canonical_name: "NeverRenderSingleton71",
            kind: "concept",
            aliases: ["NeverRenderSingleton71"],
            derived_from: [knowledge_id]
          },
          account.id,
          pipeline
        )

      create_mention!(account.id, pipeline, knowledge_id, first.id, "NeverRenderAlias71")
      create_mention!(account.id, pipeline, knowledge_id, first.id, "NRA71")
      create_mention!(account.id, pipeline, knowledge_id, second.id, "NeverRenderSingleton71")
    end)
  end

  defp ingest_statement!(admin, session_id, scope_path, content) do
    {:ok, message} =
      Memory.ingest_message(
        %{
          "session_id" => session_id,
          "scope_path" => scope_path,
          "role" => "user",
          "content" => content
        },
        admin
      )

    {:ok, [knowledge]} =
      Memory.extract_message_for_account(message["id"], admin.account_id)

    knowledge
    |> then(&%{id: Map.fetch!(&1, "id"), statement: Map.fetch!(&1, "statement")})
  end

  defp activate_knowledge!(admin, knowledge_ids) do
    DataLayer.with_actor(admin, fn account, actor ->
      pipeline = pipeline_actor(actor)

      Enum.each(knowledge_ids, fn knowledge_id ->
        item =
          KnowledgeItem
          |> Ash.Query.filter(id == ^knowledge_id)
          |> Ash.Query.set_tenant(account.id)
          |> Ash.read_one!(actor: pipeline)

        if item.state != "active" do
          GovernanceEngine.transition!(
            item,
            pipeline,
            %{state: "active", verification: "auto_verified"},
            reason: "console_entity_observability_test",
            channel: "pipeline"
          )
        end
      end)
    end)
  end

  defp link_shared_entity!(admin, knowledge_ids) do
    DataLayer.with_actor(admin, fn account, actor ->
      pipeline = pipeline_actor(actor)

      entity =
        create!(
          Entity,
          :create_from_pipeline,
          %{
            canonical_name: "NeverRenderSharedEntity71",
            kind: "concept",
            aliases: ["NeverRenderSharedEntity71"],
            derived_from: knowledge_ids
          },
          account.id,
          pipeline
        )

      knowledge_ids
      |> Enum.with_index()
      |> Enum.each(fn {knowledge_id, index} ->
        create_mention!(
          account.id,
          pipeline,
          knowledge_id,
          entity.id,
          "NeverRenderSharedSurface71-#{index}"
        )
      end)
    end)
  end

  defp create_mention!(account_id, actor, knowledge_id, entity_id, surface_form) do
    knowledge =
      KnowledgeItem
      |> Ash.Query.filter(id == ^knowledge_id)
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read_one!(actor: actor)

    create!(
      EntityMention,
      :create_from_pipeline,
      %{
        knowledge_item_id: knowledge.id,
        scope_id: knowledge.scope_id,
        entity_id: entity_id,
        surface_form: surface_form,
        confidence: 1.0
      },
      account_id,
      actor
    )
  end

  defp pipeline_actor(%Actor{} = actor),
    do: %{actor | role: :system, scope_ids: :all, pipeline?: true}

  defp create!(resource, action, attrs, account_id, actor) do
    resource
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_tenant(account_id)
    |> Ash.Changeset.for_create(action, attrs)
    |> Ash.create!(actor: actor)
  end

  defp sign_in(conn, token), do: init_test_session(conn, governance_token: token)
end
