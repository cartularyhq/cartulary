# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Pipeline.Reconciler do
  @moduledoc """
  Re-enqueues Account-local durable observations missing completed processing.

  AshOban and the `PipelineRun` identity make repeated reconciliation harmless.
  """

  alias Cartulary.Clock
  alias Cartulary.DataLayer
  alias Cartulary.Documents.ConnectorConfig
  alias Cartulary.Observations.DocumentVersion
  alias Cartulary.Observations.Message
  alias Cartulary.Pipeline

  require Ash.Query

  @spec run(Ecto.UUID.t()) :: {:ok, map()}
  def run(account_id) do
    counts =
      DataLayer.with_account_id(account_id, [role: :system, pipeline?: true], fn
        _account, actor ->
          messages =
            Message
            |> Ash.Query.filter(is_nil(extraction_completed_at))
            |> Ash.Query.set_tenant(account_id)
            |> Ash.read!(actor: actor)
            |> Enum.count(fn message ->
              match?({:ok, _run}, Pipeline.enqueue_message_extraction(message, actor))
            end)

          documents =
            DocumentVersion
            |> Ash.Query.filter(processing_status in ["pending", "failed"])
            |> Ash.Query.set_tenant(account_id)
            |> Ash.read!(actor: actor)
            |> Enum.count(fn version ->
              match?({:ok, _run}, Pipeline.enqueue_document_extraction(version, actor))
            end)

          now = Clock.utc_now()

          connectors =
            ConnectorConfig
            |> Ash.Query.filter(
              status == "active" and (is_nil(next_sync_at) or next_sync_at <= ^now)
            )
            |> Ash.Query.set_tenant(account_id)
            |> Ash.read!(actor: actor)
            |> Enum.count(fn connector ->
              match?({:ok, _run}, Pipeline.enqueue_connector_sync(connector, actor))
            end)

          %{messages: messages, documents: documents, connectors: connectors}
      end)

    {:ok, Map.put(counts, :reconciled, Enum.sum(Map.values(counts)))}
  end
end
