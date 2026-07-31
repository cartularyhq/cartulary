# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.ConsoleLiveTest do
  @moduledoc """
  End-to-end evidence for the browser console: who may open it, what each role is
    shown, and that the pages render against a real Account rather than a fixture.

    1. **An unauthenticated or machine caller reaching the console.
  """

  use CartularyWeb.ConnCase

  alias Cartulary.Accounts.ExternalIdentity
  alias Cartulary.Accounts.Peer
  alias Cartulary.Actor
  alias Cartulary.Clock
  alias Cartulary.DataLayer
  alias Cartulary.Identity
  alias Cartulary.Memory

  @password "correct horse battery staple"

  describe "reaching the console" do
    test "an anonymous visitor is sent to sign in", %{conn: conn} do
      assert redirected_to(get(conn, "/console")) == "/sign-in"
      assert redirected_to(get(conn, "/console/knowledge")) == "/sign-in"
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

    test "the personal page offers the subject gestures", %{conn: conn, admin_token: token} do
      html = conn |> sign_in(token) |> get("/console/me") |> html_response(200)

      assert html =~ "About me"
      assert html =~ "Consent requests"
      assert html =~ "Erasure"
    end

    test "operations reports readiness and the rules in force", %{
      conn: conn,
      admin_token: token
    } do
      html = conn |> sign_in(token) |> get("/console/operations") |> html_response(200)

      assert html =~ "Readiness"
      assert html =~ "Gate matrix"
      assert html =~ "Retrieval tunings"
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

    member_token = create_member!(admin)

    Map.merge(context, %{
      admin: admin,
      admin_token: admin_token,
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
    |> then(fn peer_id ->
      Identity.grant_role(admin, %{
        "scope_path" => "/",
        "peer_id" => peer_id,
        "role" => "member",
        "propagate" => false
      })
    end)

    {:ok, %{token: token}} = Identity.sign_in_password("member@example.test", @password)
    token
  end

  defp sign_in(conn, token), do: init_test_session(conn, governance_token: token)
end
