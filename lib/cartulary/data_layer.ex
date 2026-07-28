# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.DataLayer do
  @moduledoc """
  Infrastructure boundary for Account-scoped Ash transactions and PostgreSQL RLS.

  The Account comes from an authenticated actor (or a named internal
  compatibility adapter), is installed as both the Ash actor/tenant and
  transaction-local PostgreSQL settings, and cannot be overridden by action
  input. F2 uses this same transaction for domain writes, hash-chain audit,
  durable pipeline identities, and AshOban enqueue effects.
  """

  alias Cartulary.Accounts.Account
  alias Cartulary.Actor
  alias Cartulary.Repo

  require Ash.Query

  # Static bootstrap lookup retained inside the infrastructure boundary.
  # sobelow_skip ["SQL.Query"]
  def message_account_key!(message_id) do
    sql = """
    SELECT account.key
    FROM messages AS message
    JOIN accounts AS account ON account.id = message.account_id
    WHERE message.id = $1
    """

    case Ecto.Adapters.SQL.query!(Repo, sql, [Ecto.UUID.dump!(message_id)]) do
      %{rows: [[account_key]]} -> account_key
      %{rows: []} -> raise Ecto.NoResultsError, queryable: sql
    end
  end

  def with_account_key(account_key, actor_overrides \\ [], fun)
      when is_binary(account_key) and is_function(fun, 2) do
    case Repo.transaction(fn ->
           set_account_key!(account_key)

           account =
             Account
             |> Ash.Changeset.for_create(:ensure, %{
               key: account_key,
               name: account_name(account_key)
             })
             |> Ash.create!(actor: Actor.bootstrap(account_key))

           set_account_id!(account.id)
           actor = Actor.for_account(account, actor_overrides)
           fun.(account, actor)
         end) do
      {:ok, result} -> result
      {:error, error} -> raise "Account-scoped transaction failed: #{inspect(error)}"
    end
  end

  def with_free_account(fun) when is_function(fun, 2) do
    identity_config = Application.fetch_env!(:cartulary, :identity)
    account_key = Keyword.fetch!(identity_config, :account_key)
    account_name = Keyword.fetch!(identity_config, :account_name)

    case Repo.transaction(fn ->
           set_account_key!(account_key)

           account =
             Account
             |> Ash.Changeset.for_create(:provision_free, %{
               key: account_key,
               name: account_name
             })
             |> Ash.create!(actor: Actor.bootstrap(account_key))

           set_account_id!(account.id)
           actor = Actor.for_account(account, role: :system)
           fun.(account, actor)
         end) do
      {:ok, result} -> result
      {:error, error} -> raise "Free Account transaction failed: #{inspect(error)}"
    end
  end

  def with_existing_free_account(fun) when is_function(fun, 2) do
    identity_config = Application.fetch_env!(:cartulary, :identity)
    account_key = Keyword.fetch!(identity_config, :account_key)

    case Repo.transaction(fn ->
           set_account_key!(account_key)
           bootstrap_actor = Actor.bootstrap(account_key)

           account =
             Account
             |> Ash.Query.filter(key == ^account_key and edition_slot == "community-free")
             |> Ash.read_one!(actor: bootstrap_actor)

           if is_nil(account), do: raise(Ecto.NoResultsError, queryable: Account)

           set_account_id!(account.id)
           actor = Actor.for_account(account, role: :system)
           fun.(account, actor)
         end) do
      {:ok, result} -> result
      {:error, error} -> raise "Free Account lookup failed: #{inspect(error)}"
    end
  end

  def with_account_id(account_id, actor_overrides \\ [], fun)
      when is_binary(account_id) and is_function(fun, 2) do
    case Repo.transaction(fn ->
           set_account_id!(account_id)

           bootstrap_actor = %{
             account_id: account_id,
             account_key: nil,
             role: :system,
             scope_ids: :all,
             pipeline?: false
           }

           account =
             Account
             |> Ash.Query.filter(id == ^account_id)
             |> Ash.read_one!(actor: bootstrap_actor)

           actor = Actor.for_account(account, actor_overrides)
           fun.(account, actor)
         end) do
      {:ok, result} -> result
      {:error, error} -> raise "Account-scoped transaction failed: #{inspect(error)}"
    end
  end

  def with_actor(%Actor{account_id: account_id} = actor, fun)
      when is_binary(account_id) and is_function(fun, 2) do
    case Repo.transaction(fn ->
           set_account_id!(account_id)

           account =
             Account
             |> Ash.Query.filter(id == ^account_id)
             |> Ash.read_one!(actor: actor)

           fun.(account, actor)
         end) do
      {:ok, result} -> result
      {:error, error} -> raise "Identity-scoped transaction failed: #{inspect(error)}"
    end
  end

  @doc false
  def with_portability_import(account_id, account_key, fun)
      when is_binary(account_id) and is_binary(account_key) and is_function(fun, 1) do
    case Repo.transaction(fn ->
           set_account_key!(account_key)
           set_account_id!(account_id)

           actor = %Actor{
             account_id: account_id,
             account_key: account_key,
             identity_kind: :system,
             assurance: :high,
             role: :system,
             scope_ids: :all,
             scope_roles: %{},
             pipeline?: true
           }

           fun.(actor)
         end) do
      {:ok, result} -> result
      {:error, error} -> raise "Portability import transaction failed: #{inspect(error)}"
    end
  end

  defp set_account_key!(account_key) do
    Ecto.Adapters.SQL.query!(
      Repo,
      "SELECT set_config('cartulary.account_key', $1, true)",
      [account_key]
    )
  end

  defp set_account_id!(account_id) do
    Ecto.Adapters.SQL.query!(
      Repo,
      "SELECT set_config('cartulary.account_id', $1, true)",
      [account_id]
    )
  end

  defp account_name(account_key), do: String.replace(account_key, ~r/[-_]+/, " ")
end
