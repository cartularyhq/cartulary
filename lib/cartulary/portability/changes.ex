# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Portability.Changes.RestoreAttributes do
  @moduledoc """
  Writes archived attribute values back onto a row verbatim, during import only.

  Restoring an Account is not the same as authoring it again. Ordinary create
  actions accept a narrow set of caller-supplied fields and derive the rest —
  new ids, fresh timestamps, initial lifecycle state. Running an import through
  those actions would silently rewrite the history it is supposed to preserve.
  This change instead forces every archived value onto the row, so ids,
  belief-times, valid-times, lifecycle states, decision records, replay keys,
  and audit hashes come back exactly as they were. Audit chain verification
  depends on that: a re-derived timestamp would break every hash after it.

  The actions carrying this change are non-public and admit only an internal
  actor — the `:system` role or the pipeline flag — neither of which an
  externally authenticated caller can hold. It must never be exposed to an
  ordinary caller: it is, by design, a way to write attributes that no action
  would otherwise accept.

  Values are matched to attributes by name, and anything in the archive that
  the current schema no longer has is skipped rather than raising. That is
  deliberate: an archive written by an older release, or one naming a column
  since removed, still restores everything it shares with the target instead of
  failing wholesale.

  It cannot resurrect what the archive excluded. Credentials, secrets, vectors,
  and derived caches are absent from the file, so they are absent here too; the
  target rebuilds the derived ones after the import commits.
  """

  use Ash.Resource.Change

  @doc """
  Forces the `:attributes` argument's values onto the changeset.

  `:attributes` is a map of archived attribute names (strings) to values.
  Unknown names are ignored. Returns the changeset with every recognised
  attribute force-changed, bypassing the action's accept list and any default
  that would otherwise generate a new value.
  """
  @impl true
  def change(changeset, _opts, _context) do
    # Archive keys are strings, so the resource's attribute names are indexed by
    # their string form. Looking names up this way — rather than converting
    # archive keys to atoms — means an archive can never create atoms from
    # untrusted input.
    attributes =
      changeset.resource
      |> Ash.Resource.Info.attributes()
      |> Map.new(&{Atom.to_string(&1.name), &1.name})

    changeset
    |> Ash.Changeset.get_argument(:attributes)
    |> Enum.reduce(changeset, fn {key, value}, restored ->
      case Map.fetch(attributes, to_string(key)) do
        {:ok, attribute} -> Ash.Changeset.force_change_attribute(restored, attribute, value)
        :error -> restored
      end
    end)
  end
end
