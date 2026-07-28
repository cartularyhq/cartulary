# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Retrieval.Indexer do
  @moduledoc "Replay-safe F7 embedding backfill for governed knowledge."

  alias Cartulary.DataLayer
  alias Cartulary.Knowledge.KnowledgeItem
  alias Cartulary.Model.Embedding

  require Ash.Query

  def rebuild_scope(account_id, scope_id) do
    DataLayer.with_account_id(
      account_id,
      [role: :system, pipeline?: true],
      fn _account, actor ->
        items =
          KnowledgeItem
          |> Ash.Query.filter(
            scope_id == ^scope_id and state in ["active", "provisional"] and is_nil(deleted_at)
          )
          |> Ash.Query.set_tenant(account_id)
          |> Ash.read!(actor: actor)

        case items do
          [] ->
            {:ok, %{indexed: 0}}

          items ->
            index_items(items, account_id, scope_id, actor)
        end
      end
    )
  end

  defp index_items(items, account_id, scope_id, actor) do
    context = %{account_id: account_id, scope_id: scope_id, actor: actor}

    with {:ok, result} <- Embedding.embed(Enum.map(items, & &1.statement), context) do
      Enum.each(Enum.zip(items, result.vectors), fn {item, embedding} ->
        item
        |> Ash.Changeset.for_update(:index_from_pipeline, %{
          embedding: embedding,
          embedding_provider: result.provider,
          embedding_model: result.model,
          embedding_version: result.version,
          embedding_dimensions: result.dimensions
        })
        |> Ash.Changeset.set_tenant(account_id)
        |> Ash.update!(actor: actor)
      end)

      {:ok, %{indexed: length(items)}}
    end
  end
end
