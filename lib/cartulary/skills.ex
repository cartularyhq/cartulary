# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Skills do
  @moduledoc """
  Authored procedural memory and reasoning-free skill readiness checks.

  Skill cards are plain-versioned human-authored contracts. Requirements
  inherit down the scope tree with nearest-scope overrides; governed knowledge
  remains the only thing that can satisfy a requirement.
  """

  use Ash.Domain

  resources do
    resource Cartulary.Skills.SkillRequirementCard
  end

  defdelegate publish(actor, attrs), to: Cartulary.Skills.Authoring
  defdelegate check_readiness(actor, attrs), to: Cartulary.Skills.Readiness
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
      accept [
        :scope_id,
        :skill_key,
        :description,
        :requirement_schema_version,
        :version,
        :requirements,
        :active
      ]

      validate Cartulary.Skills.Validations.Requirements

      change {Cartulary.Governance.Changes.AuditResource,
              category: "configuration",
              action: "skill_requirement_card.published",
              resource_type: "skill_requirement_card",
              content_fields: [
                :skill_key,
                :description,
                :requirement_schema_version,
                :version,
                :requirements
              ]}
    end

    update :deactivate do
      accept []
      require_atomic? false
      change set_attribute(:active, false)

      change {Cartulary.Governance.Changes.AuditResource,
              category: "configuration",
              action: "skill_requirement_card.deactivated",
              resource_type: "skill_requirement_card",
              content_fields: [:skill_key, :version, :active]}
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
    attribute :description, :string, public?: true

    attribute :requirement_schema_version, :string,
      allow_nil?: false,
      default: "f9-1",
      public?: true

    attribute :version, :integer, allow_nil?: false, public?: true
    attribute :requirements, {:array, :map}, allow_nil?: false, default: [], public?: true
    attribute :active, :boolean, allow_nil?: false, default: true, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :scope_skill_version, [:scope_id, :skill_key, :version]
  end
end
