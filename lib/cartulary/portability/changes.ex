# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Portability.Changes.RestoreAttributes do
  @moduledoc false

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
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
