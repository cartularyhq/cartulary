# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Knowledge.Changes.HashStatement do
  @moduledoc """
  Ash change that stores a statement's SHA-256 hash.

  The hash is derived from statement text during creation; callers cannot supply a conflicting
  value.
  """

  use Ash.Resource.Change

  alias Cartulary.Pipeline.Idempotency

  @doc """
  Sets `statement_hash` to the lowercase hex SHA-256 of the changeset's `statement`.

  Returns the changeset unchanged when no binary statement is present. Never raises.
  """
  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :statement) do
      statement when is_binary(statement) ->
        Ash.Changeset.force_change_attribute(
          changeset,
          :statement_hash,
          Idempotency.content_hash(statement)
        )

      _other ->
        changeset
    end
  end
end
