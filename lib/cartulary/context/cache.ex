# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Context.Cache do
  @moduledoc "Node-local ETS cache for rebuildable context projections."

  use GenServer

  @table __MODULE__

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def fetch(key) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> {:ok, value}
      [] -> :error
    end
  end

  def put(key, value) do
    true = :ets.insert(@table, {key, value})
    :ok
  end

  def invalidate_scope(account_id, scope_id) do
    :ets.match_delete(@table, {{account_id, scope_id, :_}, :_})

    Phoenix.PubSub.broadcast(
      Cartulary.PubSub,
      "context-invalidation",
      {:invalidate, account_id, scope_id}
    )

    :ok
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    :ok = Phoenix.PubSub.subscribe(Cartulary.PubSub, "context-invalidation")
    {:ok, %{}}
  end

  @impl true
  def handle_info({:invalidate, account_id, scope_id}, state) do
    :ets.match_delete(@table, {{account_id, scope_id, :_}, :_})
    {:noreply, state}
  end
end
