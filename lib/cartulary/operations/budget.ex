# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Operations.BudgetCounter do
  @moduledoc """
  In-memory daily tallies used for cheap admission decisions.

  These counters are a rebuildable cache, not a record. The durable usage
  ledger is the exact history of what an Account consumed; this table exists
  only so an admission check can ask "how much today?" without aggregating that
  ledger on every call. Losing the table — a restart, a crashed owner — costs
  the current day's running totals and nothing else, which is why nothing here
  is persisted and why a lost increment is tolerated rather than retried.

  A counter is keyed by Account, scope, metric, and the current UTC calendar
  day, so tallies reset at midnight UTC simply by keying into a new bucket. Old
  days are never read again; they are left in the table and disappear with the
  process.

  ## Owning process versus the table

  The GenServer exists to own the named public table so it dies and is
  recreated with the supervision tree. It is not in the hot path: readers and
  writers hit the table directly rather than sending it messages, which is what
  keeps a per-request increment from serialising every request behind one
  process.

  ## Increments are best-effort

  Incrementing never fails the caller: if the table does not exist yet — during
  startup, or in a process tree that never started this one — the increment is
  dropped. A cache update must never be the reason a real request fails, and
  the durable ledger row has already been written by then. Reading is not
  guarded the same way, because an admission check with no table to consult
  cannot honestly answer.
  """

  use GenServer

  @table __MODULE__

  @doc """
  Starts the process that owns the counter table, registered under the module
  name.

  Started as part of the application's supervision tree; nothing else should
  start it. Options are accepted and ignored.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Adds `amount` to the Account/scope/metric tally for today, creating it at zero
  first if it does not exist.

  `scope_id` may be nil for Account-wide metrics; nil is part of the key, so
  scoped and unscoped tallies of the same metric are separate buckets and never
  merge. `metric` is an atom such as `:api_requests`, `:ingest`, or a token
  kind. `amount` must be a non-negative integer — counters only ever move
  forward, and the guard rejects a decrement rather than letting one corrupt
  the day's total.

  Always returns `:ok`, including when the table is missing.
  """
  def increment(account_id, scope_id, metric, amount)
      when is_binary(account_id) and is_atom(metric) and is_integer(amount) and amount >= 0 do
    period = Date.utc_today() |> Date.to_iso8601()
    key = {account_id, scope_id, metric, period}
    # Atomic read-modify-write inside the table, so concurrent requests for the
    # same Account cannot lose an increment to a read/write race. The trailing
    # tuple is the default row inserted when the key is absent.
    :ets.update_counter(@table, key, {2, amount}, {key, 0})
    :ok
  rescue
    # Raised when the table does not exist. Dropping a cache increment is
    # correct here; the durable ledger row was already written by the caller.
    ArgumentError -> :ok
  end

  @doc """
  Reads today's tally for one Account, scope, and metric.

  Returns the integer total, or `0` when nothing has been counted today. Zero is
  also what a caller gets after a restart, which deliberately re-opens the day's
  allowance rather than blocking traffic on an unknown total.

  Raises `ArgumentError` if the owning process has never started, so a missing
  cache surfaces instead of silently reading as "nothing consumed".
  """
  def value(account_id, scope_id, metric) do
    period = Date.utc_today() |> Date.to_iso8601()

    case :ets.lookup(@table, {account_id, scope_id, metric, period}) do
      [{_key, value}] -> value
      [] -> 0
    end
  end

  # Named and public so request and job processes can hit the table directly
  # instead of sending this process a message per increment.
  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end
end

defmodule Cartulary.Operations.Budget do
  @moduledoc """
  Decides whether a lane of work may run against today's consumption.

  Lanes are not equal, and that inequality is the whole design. Background
  reasoning is speculative work the system chose to do for itself, so it is the
  first thing denied when an Account approaches its configured token ceiling.
  User-facing work — accepting an observation, answering a governed read —
  keeps running, because throttling it would make the product look broken in
  order to save money the operator may not even be spending.

  Limits are operator configuration, expressed as a daily maximum per token
  metric. Absent configuration means no limit: a self-hoster who has set
  nothing is never throttled, rather than being throttled at some guessed
  default.

  Decisions read the rebuildable daily counters, never the durable ledger. That
  makes an admission check cheap enough to run per job, and means the worst
  consequence of a lost counter is a slightly generous day.
  """

  alias Cartulary.Operations.BudgetCounter

  # Token metrics the background reasoning lane is judged against. Request and
  # ingest counts are excluded on purpose: those lanes are never throttled here.
  @dream_metrics [:input_tokens, :output_tokens, :embedding_tokens]

  @doc """
  Whether the given lane may run now for this Account and scope.

  `lane` is the kind of work being admitted. The background reasoning lane is
  the only one with a ceiling: it is admitted only while today's tally for
  every configured token metric is still strictly below its limit. Any other
  lane is always admitted.

  Returns a boolean. A metric whose configured limit is missing, or is anything
  other than a non-negative integer, is treated as unbounded.

  A denial is a throttle, not an error. The background lane treats it as a
  successful no-op: the run finishes having done nothing, no durable state
  changes, and the work comes back the next time it is enqueued. Do not turn a
  denial into a failure — that would burn retry attempts on a decision that was
  intentional.
  """
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

  # Every other lane is user-facing or governance work. Adding a lane to the
  # throttled set is a product decision about degrading behaviour under load,
  # not a tuning change.
  def admit?(_account_id, _scope_id, _lane), do: true
end
