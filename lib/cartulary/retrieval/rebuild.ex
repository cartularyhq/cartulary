# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Retrieval.Rebuild do
  @moduledoc """
  Rebuilds one scope's derived caches in dependency order.

  All output is reconstructible. Vectors must precede entities/mentions, which must precede context
  projections; reordering can build plausible projections from stale indexes.
  """

  @doc """
  Rebuilds one scope's embeddings, entity index, and context projections.

  Stops at the first error. Completed stages remain committed; replay is the recovery path.

  Returns `{:ok, %{index: ..., entities: ..., projections: ...}}` with each
  stage's counts, or the first stage error. Raises if an underlying read or
  write fails.
  """
  def scope(account_id, scope_id) do
    with {:ok, index} <- Cartulary.Retrieval.Indexer.rebuild_scope(account_id, scope_id),
         {:ok, entities} <-
           Cartulary.Retrieval.EntityResolver.rebuild_scope(account_id, scope_id),
         {:ok, projections} <- Cartulary.Context.Builder.refresh_scope(account_id, scope_id) do
      {:ok, %{index: index, entities: entities, projections: projections}}
    end
  end
end
