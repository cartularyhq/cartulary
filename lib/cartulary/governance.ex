# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Governance do
  @moduledoc """
  Ash domain for governance records and machine tools.

  Gate A decides whether to keep an extracted claim; Gate B decides its audience. This domain
  stores tamper-evident evidence for both decisions.

  ## Durable rows this domain owns

  * `Cartulary.Governance.AuditEvent` — per-Account, hash-chained, content-safe event log.
  * `Cartulary.Governance.PolicyConfig` — versioned key/value governance settings.
  * `Cartulary.Governance.GateRule` — the versioned confidence, target-level, and sensitivity
    matrix that decides automatic keep, automatic reject, or human review.
  * `Cartulary.Governance.ValidationItem` — the queue of claims awaiting a human or peer answer.
  * `Cartulary.Governance.GateDecision` — immutable history of every automatic and human gate
    outcome.
  * `Cartulary.Governance.Consent` — subject-owned permission to place personal knowledge in a
    wider scope.
  * `Cartulary.Governance.PeerQuery` and `Cartulary.Governance.PeerQueryDelivery` — a frozen
    question and evidence that it was shown and answered.
  * `Cartulary.Governance.PeerAskPreference` — how often a peer tolerates being interrupted.
  * `Cartulary.Governance.ErasureRequest` — durable record of a subject erasure and its counted
    effects.

  `Cartulary.Governance.McpTools` is non-persisted and publishes the generic tool actions.

  ## Invariants callers must not break

  These rows are not a second knowledge store. They hold ids, hashes, or the one frozen
  statement needed for peer confirmation.

  Curator judgement is human-only. Approve, edit, reject, merge, defer, promotion, and gate-rule
  administration are reachable only from a password-session browser identity;
  `Cartulary.Policy.HumanRoleIn` refuses a machine API key even when it holds the curator role.

  Audit may contain ids, hashes, counts, timestamps, and class strings, never content or secrets.
  """

  use Ash.Domain, extensions: [AshAi]

  resources do
    resource Cartulary.Governance.AuditEvent
    resource Cartulary.Governance.PolicyConfig
    resource Cartulary.Governance.GateRule
    resource Cartulary.Governance.ValidationItem
    resource Cartulary.Governance.GateDecision
    resource Cartulary.Governance.Consent
    resource Cartulary.Governance.PeerQuery
    resource Cartulary.Governance.PeerQueryDelivery
    resource Cartulary.Governance.PeerAskPreference
    resource Cartulary.Governance.ErasureRequest
    resource Cartulary.Governance.McpTools
  end

  # Complete machine surface: raw ingest, governed reads, the caller's frozen question, and
  # lower interruption limits. Curator operations remain human-only.
  tools do
    tool(:ingest, Cartulary.Governance.McpTools, :ingest)
    tool(:get_context, Cartulary.Governance.McpTools, :get_context)
    tool(:search, Cartulary.Governance.McpTools, :search)
    tool(:ask, Cartulary.Governance.McpTools, :ask)
    tool(:query_knowledge, Cartulary.Governance.McpTools, :query_knowledge)
    tool(:check_readiness, Cartulary.Governance.McpTools, :check_readiness)
    tool(:resolve_validation, Cartulary.Governance.McpTools, :resolve_validation)
    tool(:set_ask_preference, Cartulary.Governance.McpTools, :set_ask_preference)
  end
end

defmodule Cartulary.Governance.AuditEvent do
  @moduledoc """
  One append-only, content-safe entry in an Account's tamper-evident governance audit chain.

  A row records a governance event without recording its content. `content_hash` is a digest;
  `metadata` may contain ids, counts, and class strings, never content or secrets.

  `previous_hash` links to the prior Account event. `HashAuditEvent` computes both hashes in the
  write transaction under a per-Account advisory lock, preventing concurrent chain forks.

  Only `:read` and `:record` are public. Private export/import actions are restricted to internal
  pipeline or system actors.

  Prefer `Cartulary.Governance.Audit.append/3`, which supplies the timestamp and forces a
  pipeline actor, over calling `:record` directly.
  """

  use Cartulary.Resource, domain: Cartulary.Governance, table: "audit_events"

  # Attribute tenancy and Postgres RLS independently enforce Account isolation.
  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    # Append-only. The hashing change defaults `occurred_at` and computes both chain hashes.
    create :record do
      accept [
        :scope_id,
        :actor_peer_id,
        :category,
        :action,
        :resource_type,
        :resource_id,
        :metadata,
        :content_hash,
        :occurred_at
      ]

      change Cartulary.Governance.Changes.HashAuditEvent
    end
  end

  # Account isolation always applies. Record requires governance/system role or pipeline;
  # reading requires governance/system role.
  policies do
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    policy action(:record) do
      authorize_if {Cartulary.Policy.RoleIn, roles: [:account_admin, :curator, :system]}
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    policy action_type(:read) do
      authorize_if {Cartulary.Policy.RoleIn, roles: [:account_admin, :curator, :system]}
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :scope_id, :uuid
    attribute :actor_peer_id, :uuid
    # `category` names the class of event (lifecycle, gate, attribution, deletion,
    # configuration, governance, observation); `action` is the specific verb, such as
    # "gate_rule.updated". `resource_type`/`resource_id` point at the row the event is about.
    attribute :category, :string, allow_nil?: false, public?: true
    attribute :action, :string, allow_nil?: false, public?: true
    attribute :resource_type, :string, allow_nil?: false, public?: true
    attribute :resource_id, :uuid, public?: true
    # Content-safe payload only: ids, counts, booleans, class strings. Never content itself.
    attribute :metadata, :map, allow_nil?: false, default: %{}
    # Digest of the referenced content, so a claim can be proven unchanged without storing it.
    attribute :content_hash, :string, public?: true
    # Chain links, both computed by the hashing change; nil `previous_hash` means chain start.
    attribute :previous_hash, :string
    attribute :event_hash, :string, allow_nil?: false
    attribute :occurred_at, :utc_datetime_usec, allow_nil?: false, public?: true
    create_timestamp :inserted_at
  end
end

defmodule Cartulary.Governance.PolicyConfig do
  @moduledoc """
  One versioned Account-wide or scope-specific governance setting.

  Scope, key, and version identify a row; `active` selects the live revision. A nil `scope_id`
  means Account-wide.

  Mutations audit only a digest of key, value, version, and active.

  Gate behavior lives in `GateRule`; interruption limits live in `PeerAskPreference`. This is
  the durable home for other governed configuration and is not read by current request paths.
  """

  use Cartulary.Resource, domain: Cartulary.Governance, table: "policy_configs"

  # Attribute multitenancy plus Postgres row-level security keep settings inside one Account.
  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    # Each mutation hashes the named content fields and appends one audit event after the write
    # succeeds, so a settings change can never land without leaving evidence.
    create :create do
      accept [:scope_id, :key, :value, :version, :active]

      change {Cartulary.Governance.Changes.AuditResource,
              category: "configuration",
              action: "policy_config.created",
              resource_type: "policy_config",
              content_fields: [:key, :value, :version, :active]}
    end

    # `key` and `scope_id` are not accepted here: a setting keeps its identity, and moving it
    # would break the scope/key/version identity that makes revisions comparable.
    # Atomic updates are disabled because the audit change runs in Elixir after the write.
    update :update do
      accept [:value, :version, :active]
      require_atomic? false

      change {Cartulary.Governance.Changes.AuditResource,
              category: "configuration",
              action: "policy_config.updated",
              resource_type: "policy_config",
              content_fields: [:key, :value, :version, :active]}
    end
  end

  # Account isolation applies to every action first. Configuration changes then need an admin,
  # curator, or system role. Unlike curator decisions on knowledge this check is not human-only,
  # so an API key carrying one of those roles may write settings, as may an internal actor.
  policies do
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if {Cartulary.Policy.RoleIn, roles: [:account_admin, :curator, :system]}
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    # nil means the Account-wide default rather than a setting attached to one scope.
    attribute :scope_id, :uuid, public?: true
    attribute :key, :string, allow_nil?: false, public?: true
    # Free-form map so a setting can grow fields without a migration; not exposed publicly.
    attribute :value, :map, allow_nil?: false, default: %{}
    attribute :version, :integer, allow_nil?: false, default: 1, public?: true
    attribute :active, :boolean, allow_nil?: false, default: true, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  # Revisions coexist: the unique key includes the version, which is what keeps superseded
  # settings on record instead of destroying them.
  identities do
    identity :scope_key_version, [:scope_id, :key, :version]
  end
end
