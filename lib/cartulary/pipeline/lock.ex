# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Pipeline.Lock do
  @moduledoc """
  Transaction-scoped mutual exclusion for pipeline writes that must not race.

  Idempotency keys stop the *same* unit of work from being scheduled twice, but
  they cannot stop two different units of work from concurrently discovering
  that a statement does not exist yet and both writing it. This lock closes that
  window: a merge takes the lock, then does its "does this already exist?" check
  and its write, so the second caller waits and sees the first caller's row.

  The lock name is derived from the Account plus a caller-chosen key, so it
  serialises exactly one logical operation — two Accounts, or two unrelated
  operations in one Account, never block each other.

  The same primitive protects anything with a read-then-write window: appending
  to an Account's audit chain (where two concurrent appends could otherwise read
  the same chain tip and fork it), applying a governance decision to one
  validation item, and versioning one skill card.

  ## Rules for callers

  - Take it inside a transaction. The lock is released when that transaction
    ends, not by an explicit unlock; outside a transaction it is meaningless.
  - Take it *before* the existence check, not between the check and the write.
    Locking after the read reintroduces exactly the race it exists to prevent.
  - Keep the work under it short. It is held for the rest of the transaction.

  This module writes nothing durable. It is one of the few places allowed to
  issue SQL directly, because a transaction-scoped advisory lock has no
  equivalent in the resource layer; the query is parameterised, and all durable
  state still goes through resource actions.
  """

  alias Cartulary.Repo

  @doc """
  Takes the Account/key advisory lock for the rest of the current transaction.

  `key` names the thing being serialised — a scope, subject and statement digest
  for a knowledge merge, a fixed name for the Account's audit chain, an item id
  for a governance decision. Any string works, but callers that want mutual
  exclusion must agree on the same string; two spellings of the same intent are
  two different locks and provide no protection.

  Blocks until the lock is available, then returns `:ok`. Raises if the query
  fails. Note that the name is hashed to a 64-bit integer, so distinct keys can
  in principle collide — a collision costs unnecessary waiting, never
  correctness.
  """
  @spec acquire!(Ecto.UUID.t(), String.t()) :: :ok
  def acquire!(account_id, key) do
    # Account-prefixed so one Account's merges can never block another's, and
    # transaction-scoped (`_xact_`) so the lock is always released on commit or
    # rollback — no unlock path can be forgotten or skipped by an exception.
    Ecto.Adapters.SQL.query!(
      Repo,
      "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
      ["#{account_id}:#{key}"]
    )

    :ok
  end
end
