# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Pipeline.Reconciler do
  @moduledoc """
  Re-enqueues Account-local durable observations missing completed processing.

  AshOban and the `PipelineRun` identity make repeated reconciliation harmless.
  """

  alias Cartulary.DataLayer
  alias Cartulary.Observations.Message
  alias Cartulary.Pipeline

  require Ash.Query

  @spec run(Ecto.UUID.t()) :: {:ok, map()}
  def run(account_id) do
    count =
      DataLayer.with_account_id(account_id, [role: :system, pipeline?: true], fn
        _account, actor ->
          Message
          |> Ash.Query.filter(is_nil(extraction_completed_at))
          |> Ash.Query.set_tenant(account_id)
          |> Ash.read!(actor: actor)
          |> Enum.count(fn message ->
            match?({:ok, _run}, Pipeline.enqueue_message_extraction(message, actor))
          end)
      end)

    {:ok, %{reconciled: count}}
  end
end
