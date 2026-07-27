# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Memory.Message do
  @moduledoc false

  use Ash.Resource,
    domain: Cartulary.Memory.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "messages"
    repo Cartulary.Repo
  end

  actions do
    defaults [:read]
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false, public?: true
    attribute :session_id, :uuid, allow_nil?: false, public?: true
    attribute :scope_id, :uuid, allow_nil?: false, public?: true
    attribute :peer_id, :uuid, allow_nil?: false, public?: true
    attribute :role, :string, allow_nil?: false, public?: true
    attribute :content, :string, allow_nil?: false, public?: true
    attribute :occurred_at, :utc_datetime_usec, allow_nil?: false, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end
