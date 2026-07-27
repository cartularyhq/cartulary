# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.DataLayer do
  @moduledoc """
  Infrastructure boundary for Account-scoped Ash transactions and PostgreSQL RLS.

  The Account comes from the caller adapter, is installed as both the Ash
  actor/tenant and transaction-local PostgreSQL settings, and cannot be
  overridden by action input. F2 will extend these transactions with AshOban
  and audit ownership.
  """

  alias Cartulary.Accounts.Account
  alias Cartulary.Actor
  alias Cartulary.Repo

  require Ash.Query

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
