# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Skills do
  @moduledoc "Ash domain for authored, inherited skill requirement contracts."

  use Ash.Domain

  resources do
    resource Cartulary.Skills.SkillRequirementCard
  end
end

defmodule Cartulary.Skills.SkillRequirementCard do
  @moduledoc false

  use Cartulary.Resource,
    domain: Cartulary.Skills,
    table: "skill_requirement_cards"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    create :create_version do
      accept [:scope_id, :skill_key, :version, :requirements, :active]
    end

    update :deactivate do
      accept [:active]
    end
  end

  policies do
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    policy action_type(:read) do
      authorize_if {Cartulary.Policy.ScopeAccess, attribute: :scope_id}
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if {Cartulary.Policy.RoleIn, roles: [:account_admin, :curator, :system]}
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :scope_id, :uuid, allow_nil?: false, public?: true
    attribute :skill_key, :string, allow_nil?: false, public?: true
    attribute :version, :integer, allow_nil?: false, public?: true
    attribute :requirements, {:array, :map}, allow_nil?: false, default: []
    attribute :active, :boolean, allow_nil?: false, default: true, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :scope_skill_version, [:scope_id, :skill_key, :version]
  end
end
