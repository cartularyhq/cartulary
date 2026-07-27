# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Memory.Session do
  @moduledoc false

  use Ash.Resource,
    domain: Cartulary.Memory.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "sessions"
    repo Cartulary.Repo
  end

  actions do
    defaults [:read]
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false, public?: true
    attribute :scope_id, :uuid, allow_nil?: false, public?: true
    attribute :peer_id, :uuid, allow_nil?: false, public?: true
    attribute :external_id, :string, allow_nil?: false, public?: true
    attribute :status, :string, allow_nil?: false, default: "open", public?: true
    attribute :summary, :string, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end
