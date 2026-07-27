# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Memory.Scope do
  @moduledoc false

  use Ash.Resource,
    domain: Cartulary.Memory.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "scopes"
    repo Cartulary.Repo
  end

  actions do
    defaults [:read]
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false, public?: true
    attribute :parent_id, :uuid, public?: true
    attribute :key, :string, allow_nil?: false, public?: true
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :path, :string, allow_nil?: false, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end
