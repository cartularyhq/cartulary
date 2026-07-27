# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Memory.Account do
  @moduledoc false

  use Ash.Resource,
    domain: Cartulary.Memory.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "accounts"
    repo Cartulary.Repo
  end

  actions do
    defaults [:read]
  end

  attributes do
    uuid_primary_key :id
    attribute :key, :string, allow_nil?: false, public?: true
    attribute :name, :string, allow_nil?: false, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end
