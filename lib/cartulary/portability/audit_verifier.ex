# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Portability.AuditVerifier do
  @moduledoc "Verifies the immutable per-Account audit chain before import."

  alias Cartulary.Governance.Audit

  def verify([]), do: {:ok, %{count: 0, last_hash: nil}}

  def verify(rows) when is_list(rows) do
    with :ok <- verify_event_hashes(rows),
         {:ok, root} <- single_root(rows),
         {:ok, last_hash, visited} <- walk_chain(root, rows, %{}),
         true <- map_size(visited) == length(rows) do
      {:ok, %{count: length(rows), last_hash: last_hash}}
    else
      false -> {:error, :audit_chain_disconnected}
      error -> error
    end
  end

  defp verify_event_hashes(rows) do
    Enum.reduce_while(rows, :ok, fn event, :ok ->
      payload = %{
        account_id: Map.fetch!(event, "account_id"),
        category: Map.fetch!(event, "category"),
        action: Map.fetch!(event, "action"),
        resource_type: Map.fetch!(event, "resource_type"),
        resource_id: Map.get(event, "resource_id"),
        content_hash: Map.get(event, "content_hash"),
        metadata: Map.get(event, "metadata", %{}),
        occurred_at: iso8601(Map.fetch!(event, "occurred_at")),
        previous_hash: Map.get(event, "previous_hash")
      }

      expected = Audit.content_hash(payload)

      if Map.get(event, "event_hash") == expected do
        {:cont, :ok}
      else
        {:halt, {:error, {:audit_event_hash_mismatch, Map.fetch!(event, "id")}}}
      end
    end)
  end

  defp single_root(rows) do
    case Enum.filter(rows, &is_nil(Map.get(&1, "previous_hash"))) do
      [root] -> {:ok, root}
      _other -> {:error, :audit_chain_root_invalid}
    end
  end

  defp walk_chain(event, rows, visited) do
    event_hash = Map.fetch!(event, "event_hash")

    if Map.has_key?(visited, event_hash) do
      {:error, :audit_chain_cycle}
    else
      visited = Map.put(visited, event_hash, true)

      case Enum.filter(rows, &(Map.get(&1, "previous_hash") == event_hash)) do
        [] -> {:ok, event_hash, visited}
        [next] -> walk_chain(next, rows, visited)
        _branches -> {:error, {:audit_chain_branch, Map.fetch!(event, "id")}}
      end
    end
  end

  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp iso8601(value) when is_binary(value), do: value
end
