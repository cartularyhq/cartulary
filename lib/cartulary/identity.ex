# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Identity.SigningSecret do
  @moduledoc false

  use AshAuthentication.Secret

  @impl true
  def secret_for(_name, _resource, _opts, _context) do
    :cartulary
    |> Application.fetch_env!(:identity)
    |> Keyword.fetch(:signing_secret)
  end
end

defmodule Cartulary.Identity.CredentialLocator do
  @moduledoc """
  Infrastructure bootstrap for resolving the Account embedded in an API-key
  identity before Account RLS can be installed.

  The database function accepts only the random credential id carried inside a
  valid AshAuthentication API-key envelope. It returns no peer or content data.
  The key hash is still verified by AshAuthentication inside the resolved
  Account transaction.
  """

  alias Cartulary.Repo

  def account_id_for_api_key(api_key) when is_binary(api_key) do
    with {:ok, api_key_id} <- api_key_id(api_key),
         %{rows: [[account_id]]} <-
           Ecto.Adapters.SQL.query!(
             Repo,
             "SELECT cartulary_resolve_api_key_account($1::uuid)::text",
             [api_key_id]
           ),
         true <- is_binary(account_id) do
      {:ok, account_id}
    else
      _ -> :error
    end
  rescue
    _error -> :error
  end

  def account_id_for_api_key(_api_key), do: :error

  defp api_key_id(api_key) do
    with [_prefix, middle, crc32] <- String.split(api_key, "_", parts: 3),
         {:ok, <<random_bytes::binary-size(32), id::binary-size(16)>>} <-
           AshAuthentication.Base.bindecode62(middle),
         {:ok, expected_crc32} <- AshAuthentication.Base.decode62(crc32),
         true <- expected_crc32 == :erlang.crc32(random_bytes <> id) do
      {:ok, id}
    else
      _ -> :error
    end
  end
end

defmodule Cartulary.Identity.RoleResolver do
  @moduledoc false

  alias Cartulary.Accounts.Peer
  alias Cartulary.Actor
  alias Cartulary.Topology.RoleGrant
  alias Cartulary.Topology.Scope

  require Ash.Query

  @role_rank %{reader: 1, member: 2, curator: 3, account_admin: 4}

  def resolve(account, %Peer{} = peer, identity) do
    system = Actor.for_account(account, role: :system)

    scopes =
      Scope
      |> Ash.Query.sort(path: :asc)
      |> Ash.Query.set_tenant(account.id)
      |> Ash.read!(actor: system)

    grants =
      RoleGrant
      |> Ash.Query.filter(peer_id == ^peer.id)
      |> Ash.Query.set_tenant(account.id)
      |> Ash.read!(actor: system)

    scopes_by_id = Map.new(scopes, &{&1.id, &1})
    key_scope = restricted_scope(identity[:api_key], scopes_by_id)

    scope_roles =
      scopes
      |> Enum.reduce(%{}, fn scope, roles ->
        applicable =
          Enum.filter(grants, fn grant ->
            grant_scope = Map.get(scopes_by_id, grant.scope_id)
            grant_scope && applies?(grant, grant_scope.path, scope.path)
          end)

        role =
          if Enum.any?(applicable, &(&1.effect == "deny")) do
            nil
          else
            applicable
            |> Enum.filter(&(&1.effect == "allow"))
            |> Enum.map(&role_atom/1)
            |> Enum.reject(&is_nil/1)
            |> Enum.max_by(&Map.fetch!(@role_rank, &1), fn -> nil end)
          end

        if role && inside_key_scope?(scope, key_scope) do
          Map.put(roles, scope.id, role)
        else
          roles
        end
      end)

    role =
      scope_roles
      |> Map.values()
      |> Enum.max_by(&Map.fetch!(@role_rank, &1), fn -> :reader end)

    %Actor{
      account_id: account.id,
      account_key: account.key,
      peer_id: peer.id,
      identity_id: identity[:identity_id],
      identity_kind: identity[:kind],
      assurance: identity[:assurance],
      credential_scope_id: key_scope && key_scope.id,
      role: role,
      scope_ids: Map.keys(scope_roles),
      scope_roles: scope_roles,
      pipeline?: false
    }
  end

  defp applies?(grant, grant_path, scope_path) do
    grant_path == scope_path ||
      (grant.propagate &&
         (grant_path == "/" || String.starts_with?(scope_path, grant_path <> "/")))
  end

  defp restricted_scope(nil, _scopes_by_id), do: nil
  defp restricted_scope(%{scope_id: nil}, _scopes_by_id), do: nil
  defp restricted_scope(%{scope_id: scope_id}, scopes_by_id), do: Map.get(scopes_by_id, scope_id)

  defp inside_key_scope?(_scope, nil), do: true

  defp inside_key_scope?(scope, key_scope) do
    key_scope.path == "/" || scope.path == key_scope.path ||
      String.starts_with?(scope.path, key_scope.path <> "/")
  end

  defp role_atom(%{role: "account-admin"}), do: :account_admin
  defp role_atom(%{role: "account_admin"}), do: :account_admin
  defp role_atom(%{role: "curator"}), do: :curator
  defp role_atom(%{role: "member"}), do: :member
  defp role_atom(%{role: "reader"}), do: :reader
  defp role_atom(_grant), do: nil
end

defmodule Cartulary.Identity do
  @moduledoc """
  F3 identity boundary for the community release.

  Password/JWT identities resolve inside the configured free Account. API keys
  resolve an opaque credential id to an Account and are then verified by the
  AshAuthentication API-key strategy. Both paths return the same
  identity-derived `Cartulary.Actor`.
  """

  alias AshAuthentication.{Info, Strategy}
  alias AshAuthentication.Jwt.Config, as: JwtConfig
  alias Cartulary.Accounts.ApiKey
  alias Cartulary.Accounts.ExternalIdentity
  alias Cartulary.Accounts.Peer
  alias Cartulary.Actor
  alias Cartulary.Clock
  alias Cartulary.DataLayer
  alias Cartulary.Identity.CredentialLocator
  alias Cartulary.Identity.RoleResolver
  alias Cartulary.Topology.RoleGrant
  alias Cartulary.Topology.Scope

  require Ash.Query

  def bootstrap_human(attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    DataLayer.with_free_account(fn account, system ->
      root_scope = ensure_root_scope!(account.id, system)

      peer =
        Peer
        |> Ash.Changeset.new()
        |> Ash.Changeset.set_tenant(account.id)
        |> Ash.Changeset.for_create(:register_with_password, %{
          key: Map.get(attrs, "key", normalized_key(Map.fetch!(attrs, "email"))),
          name: Map.fetch!(attrs, "name"),
          kind: "human",
          default_scope_id: root_scope.id,
          email: Map.fetch!(attrs, "email"),
          password: Map.fetch!(attrs, "password"),
          password_confirmation: Map.fetch!(attrs, "password")
        })
        |> Ash.create!(actor: system)

      identity =
        link_identity!(
          account.id,
          system,
          peer.id,
          "password",
          String.downcase(Map.fetch!(attrs, "email")),
          Map.fetch!(attrs, "email"),
          "medium"
        )

      grant_role!(
        account.id,
        system,
        root_scope.id,
        peer.id,
        "account-admin",
        "allow",
        true,
        peer.id
      )

      actor =
        RoleResolver.resolve(account, peer,
          identity_id: identity.id,
          kind: :password,
          assurance: :medium
        )

      %{account: account, peer: peer, actor: actor, token: peer.__metadata__[:token]}
    end)
  end

  def provision_agent(%Actor{role: :account_admin} = admin, attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    DataLayer.with_actor(admin, fn account, _actor ->
      system = Actor.for_account(account, role: :system)
      scope = scope_by_path!(account.id, system, Map.get(attrs, "scope_path", "/"))
      require_scope_role!(admin, scope.id, [:account_admin])

      peer =
        Peer
        |> Ash.Changeset.new()
        |> Ash.Changeset.set_tenant(account.id)
        |> Ash.Changeset.for_create(:ensure, %{
          key: Map.fetch!(attrs, "key"),
          name: Map.get(attrs, "name", Map.fetch!(attrs, "key")),
          kind: "agent",
          default_scope_id: scope.id
        })
        |> Ash.create!(actor: system)

      grant_role!(
        account.id,
        system,
        scope.id,
        peer.id,
        Map.get(attrs, "role", "member"),
        "allow",
        Map.get(attrs, "propagate", true),
        admin.peer_id
      )

      api_key =
        ApiKey
        |> Ash.Changeset.new()
        |> Ash.Changeset.set_tenant(account.id)
        |> Ash.Changeset.for_create(:create, %{
          account_id: account.id,
          peer_id: peer.id,
          scope_id: if(Map.get(attrs, "restrict_to_scope", false), do: scope.id),
          expires_at: Map.get(attrs, "expires_at")
        })
        |> Ash.create!(actor: system)

      link_identity!(
        account.id,
        system,
        peer.id,
        "apikey",
        api_key.id,
        nil,
        "high"
      )

      %{peer: peer, api_key: api_key.__metadata__[:plaintext_api_key]}
    end)
  end

  def grant_role(%Actor{role: :account_admin} = admin, attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    DataLayer.with_actor(admin, fn account, _actor ->
      system = Actor.for_account(account, role: :system)
      scope = scope_by_path!(account.id, system, Map.fetch!(attrs, "scope_path"))
      require_scope_role!(admin, scope.id, [:account_admin])

      grant_role!(
        account.id,
        system,
        scope.id,
        Map.fetch!(attrs, "peer_id"),
        Map.fetch!(attrs, "role"),
        Map.get(attrs, "effect", "allow"),
        Map.get(attrs, "propagate", true),
        admin.peer_id
      )
    end)
  end

  def authenticate_bearer("cartulary_" <> _rest = api_key), do: authenticate_api_key(api_key)
  def authenticate_bearer(token) when is_binary(token), do: authenticate_token(token)
  def authenticate_bearer(_token), do: {:error, :unauthorized}

  def sign_in_password(email, password) when is_binary(email) and is_binary(password) do
    result =
      DataLayer.with_existing_free_account(fn account, _system ->
        strategy = Info.strategy!(Peer, :password)

        case Strategy.action(
               strategy,
               :sign_in,
               %{email: email, password: password},
               tenant: account.id
             ) do
          {:ok, peer} ->
            identity =
              identity_link!(account.id, peer.id, "password", String.downcase(email))

            {:ok,
             %{
               peer: peer,
               actor:
                 RoleResolver.resolve(account, peer,
                   identity_id: identity.id,
                   kind: :password,
                   assurance: assurance_atom(identity.assurance)
                 ),
               token: peer.__metadata__[:token]
             }}

          {:error, _error} ->
            {:error, :unauthorized}
        end
      end)

    result
  rescue
    _error -> {:error, :unauthorized}
  end

  def sign_in_password(_email, _password), do: {:error, :unauthorized}

  def refresh_actor(%Actor{peer_id: peer_id} = actor) when is_binary(peer_id) do
    DataLayer.with_actor(actor, fn account, _actor ->
      system = Actor.for_account(account, role: :system)

      peer =
        Peer
        |> Ash.Query.filter(id == ^peer_id)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read_one!(actor: system)

      RoleResolver.resolve(account, peer,
        identity_id: actor.identity_id,
        kind: actor.identity_kind,
        assurance: actor.assurance,
        api_key: %{scope_id: actor.credential_scope_id}
      )
    end)
  end

  defp authenticate_api_key(api_key) do
    case CredentialLocator.account_id_for_api_key(api_key) do
      {:ok, account_id} ->
        DataLayer.with_account_id(account_id, fn account, _system ->
          authenticate_api_key_in_account(account, api_key)
        end)

      _ ->
        {:error, :unauthorized}
    end
  rescue
    _error -> {:error, :unauthorized}
  end

  defp authenticate_api_key_in_account(%{edition_slot: "community-free"} = account, api_key) do
    strategy = Info.strategy!(Peer, :api_key)

    case Strategy.action(strategy, :sign_in, %{api_key: api_key}, tenant: account.id) do
      {:ok, peer} ->
        api_key_record = peer.__metadata__[:api_key]
        identity = identity_link!(account.id, peer.id, "apikey", api_key_record.id)

        {:ok,
         RoleResolver.resolve(account, peer,
           identity_id: identity.id,
           kind: :api_key,
           assurance: assurance_atom(identity.assurance),
           api_key: api_key_record
         )}

      {:error, _error} ->
        {:error, :unauthorized}
    end
  end

  defp authenticate_api_key_in_account(_account, _api_key), do: {:error, :unauthorized}

  defp authenticate_token(token) do
    DataLayer.with_existing_free_account(fn account, _system ->
      case verify_token(token, account.id) do
        {:ok, %{"sub" => subject}} ->
          case AshAuthentication.subject_to_user(subject, Peer, tenant: account.id) do
            {:ok, peer} ->
              identity =
                identity_link!(
                  account.id,
                  peer.id,
                  "password",
                  peer.email |> to_string() |> String.downcase()
                )

              {:ok,
               RoleResolver.resolve(account, peer,
                 identity_id: identity.id,
                 kind: :password,
                 assurance: assurance_atom(identity.assurance)
               )}

            _ ->
              {:error, :unauthorized}
          end

        _ ->
          {:error, :unauthorized}
      end
    end)
  rescue
    _error -> {:error, :unauthorized}
  end

  defp verify_token(token, account_id) do
    now = Clock.utc_now() |> DateTime.to_unix()
    signer = JwtConfig.token_signer(Peer, [], %{})

    with {:ok, claims} <- Joken.verify(token, signer),
         true <- claims["tenant"] == account_id,
         true <- claims["purpose"] == "user",
         true <- is_binary(claims["sub"]) and String.starts_with?(claims["sub"], "peer?"),
         true <- is_integer(claims["exp"]) and claims["exp"] > now,
         true <- is_integer(claims["nbf"]) and claims["nbf"] <= now,
         true <-
           is_binary(claims["iss"]) and
             String.starts_with?(claims["iss"], "AshAuthentication "),
         true <- valid_audience?(claims["aud"]) do
      {:ok, claims}
    else
      _ -> :error
    end
  end

  defp valid_audience?(audience) when is_binary(audience) do
    with {:ok, requirement} <- Version.parse_requirement(audience),
         {:ok, version_chars} <- :application.get_key(:ash_authentication, :vsn),
         {:ok, version} <- version_chars |> to_string() |> Version.parse() do
      Version.match?(version, requirement)
    else
      _ -> false
    end
  end

  defp valid_audience?(_audience), do: false

  defp ensure_root_scope!(account_id, actor) do
    Scope
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_tenant(account_id)
    |> Ash.Changeset.for_create(:ensure, %{
      key: "root",
      name: "Cartulary",
      path: "/",
      state: "active"
    })
    |> Ash.create!(actor: actor)
  end

  defp scope_by_path!(account_id, actor, path) do
    Scope
    |> Ash.Query.filter(path == ^path)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read_one!(actor: actor)
  end

  defp link_identity!(
         account_id,
         actor,
         peer_id,
         provider,
         subject,
         email,
         assurance
       ) do
    ExternalIdentity
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_tenant(account_id)
    |> Ash.Changeset.for_create(:create, %{
      peer_id: peer_id,
      provider: provider,
      subject: to_string(subject),
      email: email,
      assurance: assurance,
      linked_at: Clock.utc_now(),
      active: true
    })
    |> Ash.create!(actor: actor)
  end

  defp identity_link!(account_id, peer_id, provider, subject) do
    subject = to_string(subject)

    system = %{
      account_id: account_id,
      account_key: nil,
      role: :system,
      scope_ids: :all,
      scope_roles: %{},
      pipeline?: false
    }

    ExternalIdentity
    |> Ash.Query.filter(
      peer_id == ^peer_id and provider == ^provider and subject == ^subject and
        active == true
    )
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read_one!(actor: system)
  end

  defp grant_role!(
         account_id,
         actor,
         scope_id,
         peer_id,
         role,
         effect,
         propagate,
         granted_by_peer_id
       ) do
    RoleGrant
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_tenant(account_id)
    |> Ash.Changeset.for_create(:create, %{
      scope_id: scope_id,
      peer_id: peer_id,
      role: role,
      effect: effect,
      propagate: propagate,
      granted_by_peer_id: granted_by_peer_id,
      granted_at: Clock.utc_now()
    })
    |> Ash.create!(actor: actor)
  end

  defp assurance_atom("high"), do: :high
  defp assurance_atom("medium"), do: :medium
  defp assurance_atom(_assurance), do: :low

  defp require_scope_role!(%Actor{scope_roles: scope_roles}, scope_id, permitted_roles) do
    if Map.get(scope_roles, scope_id) not in permitted_roles do
      raise Ash.Error.Forbidden, errors: []
    end
  end

  defp normalized_key(email) do
    email
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp stringify_keys(attrs), do: Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
end
