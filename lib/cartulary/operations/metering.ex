# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Operations.Metering do
  @moduledoc """
  Records what an Account consumed, and reports it back as an operator summary.

  Two things happen on every metered call, and the order matters. First the
  durable usage row is written; only then are the in-memory daily counters
  bumped. The row is the exact ledger and the counters are a rebuildable cache
  over it, so a crash between the two loses an admission hint, never a recorded
  charge. Bumping the counter first would mean the reverse.

  ## What this module owns

    * Metering of edge (HTTP) traffic, which has no model behind it. Model
      calls are metered by the model layer's single usage-emission point; this
      module only receives their token totals for the counters.
    * The Account-wide summary an administrator reads: exact recorded counts,
      token totals overall and per model role, logical storage bytes, and an
      estimated cost.

  ## Cost estimates are operator-supplied, not billing state

  There is no hidden billing service. The estimate multiplies recorded tokens
  by per-million rates the operator configured; roles with no configured rate
  contribute zero. It is a visibility aid for self-hosters and must never be
  presented as an authoritative invoice.

  ## Every database touch here opens its own Account-scoped transaction

  Nothing in this module runs inside a transaction its caller opened. Edge
  metering happens in a before-send callback, after the controller's own
  transactions have already committed; the summary is rendered by an operator
  page or a plain controller action that never opens one. Both therefore start
  on a pooled connection with no Account declared on it, and the row-level
  security policies on the usage table compare every row — read or written —
  against that declaration. Writing without one is refused outright; reading
  without one silently returns nothing, which would report an active Account as
  having consumed zero. So each entry point below wraps its own database work in
  the Account-scoped transaction helper, and a new one must do the same.

  ## Content safety

  Everything written or returned here is identifiers, counts, timings, model
  provenance, and status. Request bodies, statements, prompts, questions,
  answers, and credentials must never be added: the summary is exported to
  Account administrators, so a field added here is disclosed outside the
  governed memory boundary.
  """

  alias Cartulary.Actor
  alias Cartulary.Clock
  alias Cartulary.DataLayer
  alias Cartulary.Operations.BudgetCounter
  alias Cartulary.Operations.UsageEvent
  alias Cartulary.Repo

  @token_metrics [:input_tokens, :output_tokens, :embedding_tokens]

  @doc """
  Writes one usage-ledger row for an authenticated HTTP request, then bumps the
  daily counters.

  `attrs` must carry `:operation` (the coarse route name, for example
  `"api.ingest"`); `:scope_id`, `:http_status`, and `:status` are optional and
  `:status` defaults to `"ok"`. The row is attributed to the actor's Account and
  peer, never to anything taken from the request body.

  The provenance columns are filled with placeholders — an `"edge"` model role
  and `"none"` provider/model/version — because no model was involved. The
  pipeline version column is stamped with the literal `"f10-1"`, the same
  identity the readiness payload carries; it names the operational payload
  contract rather than an extraction pipeline. Changing that string is a
  contract transition that owes a changelog entry and updated evidence, not a
  cosmetic edit.

  Requests naming the ingest operation increment a second counter, so ingest
  volume can be throttled independently of ordinary API traffic.

  Returns `:ok`. Raises if the ledger write fails, because a call that cannot be
  metered must not be silently free; a counter update that finds no table is
  dropped instead.
  """
  def record_api(%Actor{} = actor, attrs) do
    operation = Map.fetch!(attrs, :operation)
    scope_id = Map.get(attrs, :scope_id)

    # The write needs its own Account-scoped transaction. This runs from a
    # before-send callback, so the request's own transactions have already ended
    # and the connection it lands on has no Account declared: the row-level
    # security policy on the ledger compares the new row against that
    # declaration and refuses the insert without one. Opening the transaction
    # here is also what keeps the ledger row independent of the request's
    # outcome — a request that rolled its own work back still consumed capacity.
    DataLayer.in_account_transaction(actor.account_id, fn ->
      UsageEvent
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_tenant(actor.account_id)
      |> Ash.Changeset.for_create(:record, %{
        call_id: Ecto.UUID.generate(),
        scope_id: scope_id,
        peer_id: actor.peer_id,
        operation: operation,
        model_role: "edge",
        provider: "none",
        model_name: "none",
        model_version: "none",
        prompt_version: "none",
        pipeline_version: "f10-1",
        status: Map.get(attrs, :status, "ok"),
        metadata: %{
          "http_status" => Map.get(attrs, :http_status),
          "request_count" => 1,
          "ingest_count" => if(operation == "api.ingest", do: 1, else: 0)
        },
        occurred_at: Clock.utc_now()
      })
      # The caller's own role must not decide whether its usage is recorded, so
      # the write is escalated to the internal writer that the ledger's create
      # policy admits. The Account is still the caller's.
      |> Ash.create!(actor: %{actor | role: :system, pipeline?: true})
    end)

    # Counters follow the durable write, never precede it.
    BudgetCounter.increment(actor.account_id, scope_id, :api_requests, 1)

    if operation == "api.ingest",
      do: BudgetCounter.increment(actor.account_id, scope_id, :ingest, 1)

    :ok
  end

  @doc """
  Folds one model call's token usage into the daily counters.

  Called by the model layer's usage emission point after it has written the
  durable row, so this function deliberately writes nothing durable itself.
  `usage` is a map that may carry any of `:input_tokens`, `:output_tokens`, and
  `:embedding_tokens`; a missing metric counts as zero.

  Always returns `:ok`. A failure to update a rebuildable counter must never
  fail the model call that produced the tokens.
  """
  def record_model(account_id, scope_id, usage) do
    Enum.each(@token_metrics, fn metric ->
      BudgetCounter.increment(account_id, scope_id, metric, Map.get(usage, metric, 0))
    end)
  end

  @doc """
  Builds the Account-wide usage, storage, and estimated-cost summary.

  Reads the whole ledger for the actor's Account under that actor's own
  authorization, so an actor without administrator rights gets an error rather
  than a redacted answer. Totals are computed in memory from every recorded row
  — this is exact history, not a sampled or windowed estimate — which means the
  cost of the call grows with the ledger.

  The returned map holds the recorded event count, API request and ingest
  counts, input/output/embedding token totals overall and per model role,
  logical storage bytes, an estimated model cost, and the currency that
  estimate is denominated in.

  Raises if the actor may not read the ledger.
  """
  def summary(%Actor{} = actor) do
    # Both reads happen inside one Account-scoped transaction. Callers — an
    # operator page and a controller action — hold no transaction of their own,
    # so without this the connection has no Account declared and the row-level
    # security policies filter every row away. That failure is silent: the
    # summary would report an Account with real spend as having consumed
    # nothing, which is worse than refusing to answer.
    DataLayer.in_account_transaction(actor.account_id, fn ->
      events =
        UsageEvent
        |> Ash.Query.set_tenant(actor.account_id)
        |> Ash.read!(actor: actor)

      by_role =
        events
        |> Enum.group_by(& &1.model_role)
        |> Map.new(fn {role, role_events} -> {role, token_totals(role_events)} end)

      %{
        account_id: actor.account_id,
        event_count: length(events),
        api_requests: metadata_sum(events, "request_count"),
        ingests: metadata_sum(events, "ingest_count"),
        tokens: token_totals(events),
        tokens_by_role: by_role,
        logical_storage_bytes: logical_storage_bytes(actor.account_id),
        estimated_model_cost: estimated_cost(by_role),
        currency: "USD"
      }
    end)
  end

  defp token_totals(events) do
    %{
      input: Enum.sum(Enum.map(events, & &1.input_tokens)),
      output: Enum.sum(Enum.map(events, & &1.output_tokens)),
      embedding: Enum.sum(Enum.map(events, & &1.embedding_tokens))
    }
  end

  # Metadata is a free-form map on the ledger row, so a value written by an
  # older build may be any shape. Non-integers are dropped rather than crashing
  # the summary: a malformed historical row must not make the operator view
  # permanently unreadable.
  defp metadata_sum(events, key) do
    events
    |> Enum.map(&Map.get(&1.metadata, key, 0))
    |> Enum.filter(&is_integer/1)
    |> Enum.sum()
  end

  # Raw SQL rather than an Ash aggregate because this sums byte lengths across
  # three unrelated tables in one round trip. It is read-only, the statement is
  # a fixed literal, and the Account id is the one bound parameter — and it is
  # the filter on each of the three subqueries.
  #
  # "Logical" means the size of the durable content itself — message text,
  # knowledge statements, and stored document bytes — not the on-disk size of
  # the database. Rebuildable derivations (vectors, chunks, projections) are
  # excluded on purpose, so the number reflects what an export would carry.
  #
  # A failed query yields zero rather than raising: storage size is an
  # informational field and must not take down the whole summary. That
  # forgiveness is why this must stay inside the summary's Account-scoped
  # transaction: run with no Account declared, the row-level security policies
  # on all three tables filter every row away and the honest-looking zero it
  # returns would be indistinguishable from an empty Account.
  # sobelow_skip ["SQL.Query"]
  defp logical_storage_bytes(account_id) do
    sql = """
    SELECT
      COALESCE((SELECT sum(octet_length(content)) FROM messages WHERE account_id = $1), 0) +
      COALESCE((SELECT sum(octet_length(statement)) FROM knowledge_items WHERE account_id = $1), 0) +
      COALESCE((SELECT sum(byte_size) FROM document_versions WHERE account_id = $1), 0)
    """

    # Postgres returns a sum of bigints as numeric, which the driver decodes as
    # a Decimal; the plain-integer clause covers drivers or plans that do not.
    case Ecto.Adapters.SQL.query(Repo, sql, [Ecto.UUID.dump!(account_id)]) do
      {:ok, %{rows: [[%Decimal{} = bytes]]}} -> Decimal.to_integer(bytes)
      {:ok, %{rows: [[bytes]]}} -> bytes
      _other -> 0
    end
  end

  # Rates are operator-configured price per one million tokens, per model role
  # and per token kind. An unconfigured role or kind is worth 0.0, so a
  # self-hoster who sets nothing sees an honest zero instead of a fabricated
  # number. Rounded to six decimal places because a single small call can cost
  # a fraction of a cent and truncating further would report it as free.
  defp estimated_cost(by_role) do
    rates = Application.get_env(:cartulary, :model_cost_per_million, %{})

    Enum.reduce(by_role, 0.0, fn {role, totals}, result ->
      role_rates = Map.get(rates, role, %{})

      result +
        totals.input / 1_000_000 * Map.get(role_rates, :input, 0.0) +
        totals.output / 1_000_000 * Map.get(role_rates, :output, 0.0) +
        totals.embedding / 1_000_000 * Map.get(role_rates, :embedding, 0.0)
    end)
    |> Float.round(6)
  end
end
