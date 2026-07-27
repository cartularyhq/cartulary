# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Operations do
  @moduledoc "Ash domain for append-only usage and operational ledgers."

  use Ash.Domain

  resources do
    resource Cartulary.Operations.UsageEvent
  end
end

defmodule Cartulary.Operations.UsageEvent do
  @moduledoc false

  use Cartulary.Resource, domain: Cartulary.Operations, table: "usage_events"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    create :record do
      accept [
        :scope_id,
        :peer_id,
        :operation,
        :model_role,
        :model_name,
        :input_tokens,
        :output_tokens,
        :duration_ms,
        :metadata,
        :occurred_at
      ]
    end
  end

  policies do
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    policy action(:record) do
      authorize_if {Cartulary.Policy.RoleIn, roles: [:system]}
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    policy action_type(:read) do
      authorize_if {Cartulary.Policy.RoleIn, roles: [:account_admin, :system]}
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :scope_id, :uuid
    attribute :peer_id, :uuid
    attribute :operation, :string, allow_nil?: false, public?: true
    attribute :model_role, :string, public?: true
    attribute :model_name, :string, public?: true
    attribute :input_tokens, :integer, allow_nil?: false, default: 0, public?: true
    attribute :output_tokens, :integer, allow_nil?: false, default: 0, public?: true
    attribute :duration_ms, :integer, allow_nil?: false, default: 0, public?: true
    attribute :metadata, :map, allow_nil?: false, default: %{}
    attribute :occurred_at, :utc_datetime_usec, allow_nil?: false, public?: true
    create_timestamp :inserted_at
  end
end
