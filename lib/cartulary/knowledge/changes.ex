# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Knowledge.Changes.HashStatement do
  @moduledoc """
  Ash change that derives a knowledge statement's SHA-256 hash from its text.

  The hash is computed here, never accepted from a caller, because several mechanisms trust it:
  deduplication (a re-observed statement corroborates the existing row instead of creating a
  twin), the extraction advisory lock keyed on the same digest of the same text, and the audit
  chain, which records this hash *instead of* the statement so the audit log stays free of
  content.

  A caller-supplied hash would let two different statements claim the same identity, so the
  change force-writes the attribute and the create action it is attached to does not accept
  `statement_hash` at all.

  When the changeset carries no statement (or a non-binary value) the changeset is returned
  untouched, so the resource's own `allow_nil?` and length constraints report the error rather
  than this change failing with a less useful one.
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
