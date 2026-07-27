# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.F3IdentityTenancyBasicRbacTest do
  use CartularyWeb.ConnCase, async: false
  use ExUnitProperties

  alias Cartulary.Accounts.ApiKey
  alias Cartulary.Accounts.Peer
  alias Cartulary.DataLayer
  alias Cartulary.Identity
  alias Cartulary.Identity.RoleResolver
  alias Cartulary.Repo
  alias Cartulary.Topology.RoleGrant
  alias Cartulary.Topology.Scope
  alias Cartulary.Topology.ScopeRelation

  require Ash.Query

  test "password and API-key strategies derive one Account and linked Peer identities", %{
    conn: conn
  } do
    bootstrap = bootstrap_human!()

    assert {:ok, %{actor: password_actor, token: password_token}} =
             Identity.sign_in_password("admin@example.test", "correct horse battery staple")

    assert password_actor.account_id == bootstrap.account.id
    assert password_actor.peer_id == bootstrap.peer.id
    assert password_actor.identity_kind == :password
    assert password_actor.assurance == :medium
    assert password_actor.role == :account_admin

    assert {:error, :unauthorized} =
             Identity.sign_in_password("admin@example.test", "not the password")

    assert %{"data" => %{"token" => endpoint_token, "token_type" => "Bearer"}} =
             conn
             |> post(~p"/api/auth/password", %{
               "email" => "admin@example.test",
               "password" => "correct horse battery staple"
             })
             |> json_response(200)

    assert is_binary(password_token)
    assert is_binary(endpoint_token)

    agent =
      Identity.provision_agent(bootstrap.actor, %{
        key: "agent-one",
        name: "Agent One",
        scope_path: "/",
        role: "member"
      })

    assert String.starts_with?(agent.api_key, "cartulary_")
    assert {:ok, api_actor} = Identity.authenticate_bearer(agent.api_key)
    assert api_actor.account_id == bootstrap.account.id
    assert api_actor.peer_id == agent.peer.id
    assert api_actor.identity_kind == :api_key
    assert api_actor.assurance == :high
    assert api_actor.role == :member

    assert %{rows: [[2]]} =
             Ecto.Adapters.SQL.query!(
               Repo,
               "SELECT count(*) FROM external_identities WHERE account_id = $1",
               [Ecto.UUID.dump!(bootstrap.account.id)]
             )

    refute database_contains_plaintext?(agent.api_key)
  end

  test "the community free slot permits one authenticated Account", _context do
    bootstrap = bootstrap_human!()

    assert bootstrap.account.edition_slot == "community-free"

    assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
             Ecto.Adapters.SQL.query(
               Repo,
               """
               INSERT INTO accounts
                 (id, key, name, edition_slot, inserted_at, updated_at)
               VALUES
                 (gen_random_uuid(), 'second-free', 'Second Free',
                  'community-free', NOW(), NOW())
               """
             )
  end

  test "unknown and malformed credentials return the same non-leaking failure", %{conn: conn} do
    bootstrap_human!()
    foreign_api_key = foreign_api_key!()

    missing = post(conn, ~p"/api/v1/search", %{"query" => "anything"})

    malformed =
      conn
      |> put_req_header("authorization", "Bearer cartulary_not-a-real-key")
      |> post(~p"/api/v1/search", %{"query" => "anything"})

    foreign =
      conn
      |> put_req_header("authorization", "Bearer #{foreign_api_key}")
      |> post(~p"/api/v1/search", %{"query" => "anything"})

    assert missing.status == 401
    assert malformed.status == 401
    assert foreign.status == 401
    assert missing.resp_body == malformed.resp_body
    assert missing.resp_body == foreign.resp_body
    assert Jason.decode!(missing.resp_body) == %{"error" => "Unauthorized"}
  end

  test "cross-linked scopes are visible only when both endpoints are authorized" do
    unique = System.unique_integer([:positive])

    DataLayer.with_account_key("f3-link-#{unique}", [role: :system], fn account, system ->
      peer = create_peer!(account.id, system, "link-peer-#{unique}")
      source = create_scope!(account.id, system, "/link-#{unique}/source", nil)
      target = create_scope!(account.id, system, "/link-#{unique}/target", nil)

      create_grant!(account.id, system, source.id, peer.id, "reader", "allow", false)

      relation =
        ScopeRelation
        |> Ash.Changeset.new()
        |> Ash.Changeset.set_tenant(account.id)
        |> Ash.Changeset.for_create(:create, %{
          source_scope_id: source.id,
          target_scope_id: target.id,
          kind: "related"
        })
        |> Ash.create!(actor: system)

      source_only = RoleResolver.resolve(account, peer, kind: :password, assurance: :medium)

      assert [] =
               ScopeRelation
               |> Ash.Query.filter(id == ^relation.id)
               |> Ash.Query.set_tenant(account.id)
               |> Ash.read!(actor: source_only)

      create_grant!(account.id, system, target.id, peer.id, "reader", "allow", false)
      both = RoleResolver.resolve(account, peer, kind: :password, assurance: :medium)

      assert [%ScopeRelation{id: relation_id}] =
               ScopeRelation
               |> Ash.Query.filter(id == ^relation.id)
               |> Ash.Query.set_tenant(account.id)
               |> Ash.read!(actor: both)

      assert relation_id == relation.id
    end)
  end

  property "Account policy never exposes a foreign tenant" do
    check all(
            suffix <- string(:alphanumeric, min_length: 4, max_length: 12),
            max_runs: 12
          ) do
      unique = "#{suffix}-#{System.unique_integer([:positive])}"

      {account_a, actor_a} =
        DataLayer.with_account_key("f3-wall-a-#{unique}", [role: :system], fn account, actor ->
          create_scope!(account.id, actor, "/wall-a-#{unique}", nil)
          {account, actor}
        end)

      account_b =
        DataLayer.with_account_key("f3-wall-b-#{unique}", [role: :system], fn account, actor ->
          create_scope!(account.id, actor, "/wall-b-#{unique}", nil)
          account
        end)

      assert account_a.id != account_b.id

      assert [] =
               Scope
               |> Ash.Query.set_tenant(account_b.id)
               |> Ash.read!(actor: actor_a)
    end
  end

  property "propagating allows inherit down containment and any applicable deny wins" do
    check all(
            child_count <- integer(1..5),
            propagate <- boolean(),
            deny_at <- one_of([constant(nil), integer(0..5)]),
            max_runs: 20
          ) do
      unique = System.unique_integer([:positive])

      DataLayer.with_account_key("f3-rbac-#{unique}", [role: :system], fn account, system ->
        peer = create_peer!(account.id, system, "rbac-peer-#{unique}")

        scopes =
          Enum.reduce(0..child_count, [], fn index, scopes ->
            parent = List.last(scopes)
            path = "/rbac-#{unique}/" <> Enum.map_join(0..index, "/", &"s#{&1}")
            scopes ++ [create_scope!(account.id, system, path, parent && parent.id)]
          end)

        root = hd(scopes)
        create_grant!(account.id, system, root.id, peer.id, "member", "allow", propagate)

        effective_deny_at =
          if is_integer(deny_at) && deny_at <= child_count, do: deny_at

        if effective_deny_at do
          denied_scope = Enum.at(scopes, effective_deny_at)

          create_grant!(
            account.id,
            system,
            denied_scope.id,
            peer.id,
            "member",
            "deny",
            true
          )
        end

        actor = RoleResolver.resolve(account, peer, kind: :password, assurance: :medium)
        actual = MapSet.new(actor.scope_ids)

        expected =
          scopes
          |> Enum.with_index()
          |> Enum.filter(fn {_scope, index} ->
            allowed = index == 0 || propagate
            denied = is_integer(effective_deny_at) && index >= effective_deny_at
            allowed && !denied
          end)
          |> MapSet.new(fn {scope, _index} -> scope.id end)

        assert actual == expected
      end)
    end
  end

  defp bootstrap_human! do
    Identity.bootstrap_human(%{
      email: "admin@example.test",
      name: "Test Admin",
      password: "correct horse battery staple"
    })
  end

  defp create_peer!(account_id, actor, key) do
    Peer
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_tenant(account_id)
    |> Ash.Changeset.for_create(:ensure, %{key: key, name: key, kind: "human"})
    |> Ash.create!(actor: actor)
  end

  defp create_scope!(account_id, actor, path, parent_id) do
    key = path |> String.split("/", trim: true) |> List.last()

    Scope
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_tenant(account_id)
    |> Ash.Changeset.for_create(:ensure, %{
      parent_id: parent_id,
      key: key,
      name: key,
      path: path,
      state: "active"
    })
    |> Ash.create!(actor: actor)
  end

  defp create_grant!(account_id, actor, scope_id, peer_id, role, effect, propagate) do
    RoleGrant
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_tenant(account_id)
    |> Ash.Changeset.for_create(:create, %{
      scope_id: scope_id,
      peer_id: peer_id,
      role: role,
      effect: effect,
      propagate: propagate,
      granted_at: Cartulary.Clock.utc_now()
    })
    |> Ash.create!(actor: actor)
  end

  defp database_contains_plaintext?(plaintext) do
    %{rows: [[found]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT EXISTS (
          SELECT 1
          FROM api_keys
          WHERE encode(api_key_hash, 'escape') = $1
        )
        """,
        [plaintext]
      )

    found
  end

  defp foreign_api_key! do
    unique = System.unique_integer([:positive])

    DataLayer.with_account_key("f3-foreign-#{unique}", [role: :system], fn account, system ->
      peer = create_peer!(account.id, system, "foreign-peer-#{unique}")

      api_key =
        ApiKey
        |> Ash.Changeset.new()
        |> Ash.Changeset.set_tenant(account.id)
        |> Ash.Changeset.for_create(:create, %{
          account_id: account.id,
          peer_id: peer.id
        })
        |> Ash.create!(actor: system)

      api_key.__metadata__[:plaintext_api_key]
    end)
  end
end
