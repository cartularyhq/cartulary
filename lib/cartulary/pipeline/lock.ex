# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Pipeline.Lock do
  @moduledoc """
  Transaction-scoped Postgres advisory locks for idempotent pipeline writes.

  The lock is account/key scoped. It serializes one logical merge without
  serializing unrelated Accounts or statements.
  """

  alias Cartulary.Repo

  @spec acquire!(Ecto.UUID.t(), String.t()) :: :ok
  def acquire!(account_id, key) do
    Ecto.Adapters.SQL.query!(
      Repo,
      "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
      ["#{account_id}:#{key}"]
    )

    :ok
  end
end
