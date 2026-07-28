# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Retrieval.Rebuild do
  @moduledoc """
  Rebuilds every derived cache for one scope, in the order they depend on each
  other.

  The system distinguishes two kinds of data: the durable record — raw
  messages, approved statements, audit entries — and caches derived from it.
  Everything this module writes is the second kind. It can all be deleted and
  regenerated from the durable record, which is what makes it safe to run after
  a logical import, after an erasure, or whenever an index is suspected stale.

  Order is a real dependency chain, not a preference. The projection refresh
  ranks a scope's statements with the thorough retrieval posture, which reads
  both the statement vectors and the entity index:

  1. **Vectors** first.
  2. **Entities and mentions** next.
  3. **Context projections** last, so they are assembled from indexes that are
     already current.

  Reordering the steps produces projections built on stale indexes — output
  that looks entirely plausible and is quietly wrong.
  """

  @doc """
  Rebuilds one scope's embeddings, entity index, and context projections.

  Stops at the first stage that returns an error and propagates it, leaving
  later stages unrun; the already-rebuilt stages keep their new state, since
  each stage commits its own transaction. Re-running after a failure is the
  intended recovery, and is safe because every stage is replay-safe on its own.

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
