# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Context.Cache do
  @moduledoc """
  Node-local in-memory cache of clean context projections, with cluster-wide invalidation.

  Context assembly happens on every agent turn, so re-reading the same scope card from the
  database each time is wasted work. This module keeps those rows in an ETS table on each node
  and evicts them when a scope's projections change.

  ## Keys and what may be cached

  Entries are keyed by the triple `{account id, scope id, projection cache key}`. The Account id
  is part of the key, not an afterthought: two Accounts hold structurally identical scope and
  projection keys, and dropping the Account component would serve one tenant's card to another.
  Only projections that were clean when read are stored — the read path filters dirty rows
  before they ever reach `put/2`.

  ## Invalidation is a broadcast, not a local delete

  In queue mode several nodes serve requests and each holds its own table. A rebuild or a
  lifecycle change on one node must evict the same key everywhere, so `invalidate_scope/2`
  deletes locally *and* publishes the eviction; every node's cache process applies it. Skipping
  the broadcast leaves other nodes serving a card whose statements have changed.

  ## Ownership

  The table is public and named, so readers hit ETS directly instead of queueing behind this
  process; the GenServer exists to own the table's lifetime and to receive invalidation
  messages. The table is therefore lost if the process restarts, which is harmless — every
  entry is a copy of a database row and the next read repopulates it.
  """

  use GenServer

  @table __MODULE__

  @doc """
  Starts the cache process, which owns the ETS table and subscribes to invalidations.

  Started by the application supervisor. Options are ignored; the process is registered under
  the module name because both the table and the subscription are node-singletons.
  """
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Looks up one cached projection.

  `key` is the `{account id, scope id, projection cache key}` triple. Returns `{:ok, projection}`
  or `:error` when the entry is absent. Reads the public table directly from the calling
  process, so it does not block on the cache process.
  """
  def fetch(key) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> {:ok, value}
      [] -> :error
    end
  end

  @doc """
  Stores one projection under the `{account id, scope id, projection cache key}` triple.

  Callers must only store projections that are not marked dirty; this function does not check,
  because it never sees the surrounding query. Returns `:ok`.
  """
  def put(key, value) do
    true = :ets.insert(@table, {key, value})
    :ok
  end

  @doc """
  Evicts every cached projection for one scope on every node.

  Deletes the local entries immediately, then broadcasts so the other nodes' caches do the same.
  Call this after rebuilding a scope's projections or after marking them dirty; a database
  update alone does not reach these copies. Returns `:ok`.
  """
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
    # Public so any request process can read and write without a round trip through this
    # GenServer; read-concurrency because the table is read on every context assembly and
    # written only on a projection miss or an eviction.
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    :ok = Phoenix.PubSub.subscribe(Cartulary.PubSub, "context-invalidation")
    {:ok, %{}}
  end

  @impl true
  def handle_info({:invalidate, account_id, scope_id}, state) do
    # The originating node also receives its own broadcast and deletes a second time. That is
    # intentional: a delete is idempotent, and filtering by sender would be more fragile than
    # the redundant match_delete.
    :ets.match_delete(@table, {{account_id, scope_id, :_}, :_})
    {:noreply, state}
  end
end
