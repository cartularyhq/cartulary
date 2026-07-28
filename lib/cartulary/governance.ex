# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Governance do
  @moduledoc """
  Ash domain for the audit chain, the gate decision records, and the machine tool surface.

  Governance is the part of the system that decides whether an extracted claim may become
  visible memory, and that keeps tamper-evident evidence of every such decision. Agents and
  connectors submit raw observations; the extraction pipeline proposes claims; nothing becomes
  readable memory until the two gates in this domain say so. Gate A asks "is this claim worth
  keeping at all", Gate B asks "how widely may it be placed".

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
  * `Cartulary.Governance.PeerQuery` and `Cartulary.Governance.PeerQueryDelivery` — the frozen
    question asked back to a peer inside a session, plus the evidence that the exact text was
    shown and answered.
  * `Cartulary.Governance.PeerAskPreference` — how often a peer tolerates being interrupted.
  * `Cartulary.Governance.ErasureRequest` — durable record of a subject erasure and its counted
    effects.

  `Cartulary.Governance.McpTools` is the one non-persisted member; it exists only to carry the
  generic actions published as tools.

  ## Invariants callers must not break

  Knowledge is the only durable atom. Nothing here is a second store of statements: these rows
  hold a knowledge id, a statement hash, or one frozen copy of a single statement that a peer
  was asked to confirm.

  Curator judgement is human-only. Approve, edit, reject, merge, defer, promotion, and gate-rule
  administration are reachable only from a password-session browser identity;
  `Cartulary.Policy.HumanRoleIn` refuses a machine API key even when it holds the curator role.

  Audit stays content-safe. Ids, hashes, counts, timestamps, and class strings are allowed;
  raw message text, statements, prompts, answers, keys, and secrets are not.
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

  # This is the complete machine-facing tool surface. It is deliberately limited to submitting
  # raw observations, reading governed memory, answering the calling peer's own frozen question,
  # and lowering that same peer's interruption limits. Do not add a curator tool here: approve,
  # edit, reject, merge, defer, promotion, and gate-rule administration are human-only, and the
  # resources behind them refuse a machine credential anyway.
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

  A row records that something governance-relevant happened — a lifecycle transition, a gate
  decision, an attribution change, a deletion, a configuration change, or an accepted
  observation. It never records what was said. `content_hash` is a digest of the content the
  event refers to and `metadata` holds ids, counts, and class strings; both must stay free of
  raw message text, statements, prompts, answers, API keys, and secrets. That rule is what lets
  the log be kept forever even after the underlying content is erased.

  Rows are chained. `previous_hash` is the `event_hash` of the previous row for the same
  Account, and `event_hash` digests this row's fields together with that predecessor, so
  altering or dropping any historical row invalidates every later hash.
  `Cartulary.Governance.Changes.HashAuditEvent` computes both inside the write transaction under
  a per-Account advisory lock, which is what stops two concurrent appends from claiming the same
  predecessor and forking the chain.

  Only `:read` and `:record` are defined, so history cannot be rewritten in place. The shared
  resource macro additionally injects private export/import actions used by whole-Account
  archives; those are restricted to the internal pipeline or system actor.

  Prefer `Cartulary.Governance.Audit.append/3`, which supplies the timestamp and forces a
  pipeline actor, over calling `:record` directly.
  """

  use Cartulary.Resource, domain: Cartulary.Governance, table: "audit_events"

  # Attribute multitenancy pins every read and write to the tenant Account. Postgres row-level
  # security on this table is the independent second wall; neither one is sufficient alone.
  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    # Append-only: there is no update or destroy counterpart by design. `occurred_at` is accepted
    # so a caller can record when the event really happened; the hashing change fills in the
    # current time when it is omitted, and always computes previous_hash/event_hash itself.
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

  # Every policy block must pass, so the first clause is the Account wall: no later clause can
  # widen it, and a row belonging to another Account is invisible regardless of role. Appending
  # then needs an admin, curator, or system role, or the internal pipeline actor; reading needs
  # one of those roles, and the pipeline flag alone does not grant it. Ordinary members and
  # readers cannot browse the audit log at all.
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
  One versioned governance setting: a named key with a map value, held Account-wide or at a
  single scope.

  A row is unique on scope, key, and version, so publishing a revision appends a new row rather
  than overwriting the old one, and `active` marks which revision is in force. A nil `scope_id`
  means the setting is Account-wide; a set `scope_id` attaches it to that one scope.

  Both mutations append a configuration entry to the audit chain. Only a digest of key, value,
  version, and active reaches the log, so the setting value itself is never copied into audit.

  This is not where gate behaviour is decided: the confidence and placement matrix lives in
  `Cartulary.Governance.GateRule` and interruption limits in
  `Cartulary.Governance.PeerAskPreference`. This table is the durable, exportable home for other
  governed configuration, and nothing in the current request path reads it.
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
