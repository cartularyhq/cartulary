# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Operations.Metering do
  @moduledoc "Exact API/ingest ledger emission and self-host cost visibility."

  alias Cartulary.Actor
  alias Cartulary.Clock
  alias Cartulary.Operations.BudgetCounter
  alias Cartulary.Operations.UsageEvent
  alias Cartulary.Repo

  @token_metrics [:input_tokens, :output_tokens, :embedding_tokens]

  def record_api(%Actor{} = actor, attrs) do
    operation = Map.fetch!(attrs, :operation)
    scope_id = Map.get(attrs, :scope_id)

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
    |> Ash.create!(actor: %{actor | role: :system, pipeline?: true})

    BudgetCounter.increment(actor.account_id, scope_id, :api_requests, 1)

    if operation == "api.ingest",
      do: BudgetCounter.increment(actor.account_id, scope_id, :ingest, 1)

    :ok
  end

  def record_model(account_id, scope_id, usage) do
    Enum.each(@token_metrics, fn metric ->
      BudgetCounter.increment(account_id, scope_id, metric, Map.get(usage, metric, 0))
    end)
  end

  def summary(%Actor{} = actor) do
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
  end

  defp token_totals(events) do
    %{
      input: Enum.sum(Enum.map(events, & &1.input_tokens)),
      output: Enum.sum(Enum.map(events, & &1.output_tokens)),
      embedding: Enum.sum(Enum.map(events, & &1.embedding_tokens))
    }
  end

  defp metadata_sum(events, key) do
    events
    |> Enum.map(&Map.get(&1.metadata, key, 0))
    |> Enum.filter(&is_integer/1)
    |> Enum.sum()
  end

  # Static, parameterized aggregate inside the F10 operations read boundary.
  # sobelow_skip ["SQL.Query"]
  defp logical_storage_bytes(account_id) do
    sql = """
    SELECT
      COALESCE((SELECT sum(octet_length(content)) FROM messages WHERE account_id = $1), 0) +
      COALESCE((SELECT sum(octet_length(statement)) FROM knowledge_items WHERE account_id = $1), 0) +
      COALESCE((SELECT sum(byte_size) FROM document_versions WHERE account_id = $1), 0)
    """

    case Ecto.Adapters.SQL.query(Repo, sql, [Ecto.UUID.dump!(account_id)]) do
      {:ok, %{rows: [[%Decimal{} = bytes]]}} -> Decimal.to_integer(bytes)
      {:ok, %{rows: [[bytes]]}} -> bytes
      _other -> 0
    end
  end

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
