# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Knowledge.Changes.HashStatement do
  @moduledoc false

  use Ash.Resource.Change

  alias Cartulary.Pipeline.Idempotency

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
