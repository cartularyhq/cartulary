# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Retrieval.Rebuild do
  @moduledoc "Replay-safe backfill of vectors, entities, mentions, and context projections."

  def scope(account_id, scope_id) do
    with {:ok, index} <- Cartulary.Retrieval.Indexer.rebuild_scope(account_id, scope_id),
         {:ok, entities} <-
           Cartulary.Retrieval.EntityResolver.rebuild_scope(account_id, scope_id),
         {:ok, projections} <- Cartulary.Context.Builder.refresh_scope(account_id, scope_id) do
      {:ok, %{index: index, entities: entities, projections: projections}}
    end
  end
end
