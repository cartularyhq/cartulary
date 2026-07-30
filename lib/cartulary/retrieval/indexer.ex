# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Retrieval.Indexer do
  @moduledoc """
  Recomputes the embedding vectors that semantic retrieval searches, for every
  statement in a scope.

  Vectors are a derived cache. Losing them costs semantic recall until this
  runs again; it never loses a statement, because the statement text is the
  durable record and the vector is only an index over it. That is what makes
  this safe to run at any time.

  It is needed whenever vectors and statements fall out of step: after a
  logical import, after an erasure, after a statement is approved while the
  embedder was unavailable, or after the Account switches to a different
  embedder and the old vectors stop being usable.

  Runs as a background job, never on a request path — it embeds the whole scope
  in one call and then updates one row per statement.

  ## Three phases, and the embedding call holds no connection

  A rebuild is a short read transaction, then the embedding call with no
  transaction open, then a short write transaction. The split is not
  cosmetic. A transaction owns one pooled database connection for its whole
  duration, and a batched embedding call against a hosted embedder is a network
  round trip whose duration grows with the scope. Holding a connection across
  it exceeds DBConnection's checkout-ownership timeout, which closes the
  connection mid-transaction and discards every write in it — including the
  writes recording an embedding call that already happened and was already
  billed. Do not reunite the phases.

  Each write records which embedder produced the vector (provider, model,
  version, dimensions) alongside it. Semantic search then only compares vectors
  from the identical embedder, so a half-migrated scope returns fewer results
  rather than nonsensical ones.
  """

  alias Cartulary.DataLayer
  alias Cartulary.Knowledge.KnowledgeItem
  alias Cartulary.Model.Embedding

  require Ash.Query

  @doc """
  Re-embeds every indexable statement in one scope.

  Covers both approved statements and provisional ones, since a provisional
  statement is retrievable by the peer it is about and needs a vector too;
  soft-deleted statements are skipped so erased content stays out of the index.

  Replay-safe: it overwrites vectors rather than accumulating them, so running
  it repeatedly converges. Every write happens in the final transaction, so a
  failure at any point — including inside the embedder — leaves the previous
  vectors in place instead of a partially re-embedded scope.

  Returns `{:ok, %{indexed: n}}`, with zero when the scope has nothing to
  index, or the embedding provider's error tuple. Raises if a read or write
  fails.
  """
  def rebuild_scope(account_id, scope_id) do
    {items, actor} = read_items!(account_id, scope_id)

    case items do
      # Return early rather than calling the embedder with an empty list,
      # which some providers reject outright.
      [] -> {:ok, %{indexed: 0}}
      items -> embed_then_write(items, account_id, scope_id, actor)
    end
  end

  # Phase one. Covers both approved and provisional statements and skips
  # soft-deleted ones, so erased content stays out of the index.
  #
  # The actor is returned alongside the rows because phase two needs one and
  # runs with no transaction open. That is safe: an actor is a plain struct
  # naming the Account and the authorization role, so it stays valid after the
  # transaction that produced it ends, and the model layer uses it to scope its
  # own configuration read and usage write.
  defp read_items!(account_id, scope_id) do
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

        {items, actor}
      end
    )
  end

  # Phases two and three. One batched embedding call for the whole scope with no
  # transaction open, then one write per statement in a second short
  # transaction. The pairing relies on the provider returning vectors in the
  # same order as the submitted texts; a reordering here would attach each
  # vector to the wrong statement and silently corrupt semantic search.
  #
  # An embedding failure short-circuits before the write transaction opens, so
  # the scope keeps whatever vectors it already had and the job retries.
  defp embed_then_write(items, account_id, scope_id, actor) do
    context = %{account_id: account_id, scope_id: scope_id, actor: actor}

    with {:ok, result} <- Embedding.embed(Enum.map(items, & &1.statement), context) do
      DataLayer.with_account_id(
        account_id,
        [role: :system, pipeline?: true],
        fn _account, actor ->
          Enum.each(Enum.zip(items, result.vectors), fn {item, embedding} ->
            item
            # A dedicated action that only touches index columns. It is the
            # sole way a knowledge vector is written, which keeps the derived
            # index out of the actions that change a statement's meaning or
            # lifecycle.
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
        end
      )

      {:ok, %{indexed: length(items)}}
    end
  end
end
