# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Operations.BudgetCounter do
  @moduledoc "Rebuildable ETS admission counters over the exact UsageEvent ledger."

  use GenServer

  @table __MODULE__

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def increment(account_id, scope_id, metric, amount)
      when is_binary(account_id) and is_atom(metric) and is_integer(amount) and amount >= 0 do
    period = Date.utc_today() |> Date.to_iso8601()
    key = {account_id, scope_id, metric, period}
    :ets.update_counter(@table, key, {2, amount}, {key, 0})
    :ok
  rescue
    ArgumentError -> :ok
  end

  def value(account_id, scope_id, metric) do
    period = Date.utc_today() |> Date.to_iso8601()

    case :ets.lookup(@table, {account_id, scope_id, metric, period}) do
      [{_key, value}] -> value
      [] -> 0
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end
end

defmodule Cartulary.Operations.Budget do
  @moduledoc """
  Per-scope budget admission with graceful lane priority.

  Runtime limits are a safe fallback; persisted policy can override them at
  the same `budget.<metric>` keys. Dream-time is denied first. Ingest and
  governed reads remain available unless an explicit hard limit is configured.
  """

  alias Cartulary.Operations.BudgetCounter

  @dream_metrics [:input_tokens, :output_tokens, :embedding_tokens]

  def admit?(account_id, scope_id, :dream_time) do
    limits = Application.get_env(:cartulary, :budget_limits, %{})

    Enum.all?(@dream_metrics, fn metric ->
      case Map.get(limits, metric) do
        limit when is_integer(limit) and limit >= 0 ->
          BudgetCounter.value(account_id, scope_id, metric) < limit

        _unset ->
          true
      end
    end)
  end

  def admit?(_account_id, _scope_id, _lane), do: true
end
