# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Topology do
  @moduledoc """
  Ash domain for the scope tree: where things live, what is linked to what, and who may act where.

  Almost everything in Cartulary is attached to a scope, and this domain
  defines what a scope is. Scopes form a containment tree inside one Account,
  addressed by slash-delimited paths — `/`, `/team`, `/team/project`. Three
  rules follow from that shape, and the rest of the system relies on all three.

  ## Context flows down, nearest wins

  Anything attached to a scope is visible to the scopes contained within it. A
  statement recorded at `/team` is in context at `/team/project`; the reverse
  is not true, and moving knowledge upward is a governed decision made
  elsewhere, never an automatic consequence of the tree. Where several
  ancestors offer a value for the same thing — a retrieval override, a skill
  requirement, a role — the nearest enclosing scope wins, so a specific place
  can always override a general one. Callers that rely on this order receive
  scope lists sorted nearest-first; re-sorting such a list inverts the rule.

  ## Deny wins over inherited allows

  A role grant attaches a role to a peer at one scope and says whether it
  propagates downward. When several grants reach the same scope, any applicable
  deny removes that scope outright — it is not weighed against allows and
  cannot be out-ranked by a stronger role. That is what makes a deny a
  dependable way to carve a hole in a broad inherited grant.

  ## A link is not a grant

  Relations connect scopes that are not in a parent-child line. They can widen
  what retrieval *considers*, but never what a caller may *see*: expansion
  across a relation only happens when the caller is already authorized at both
  ends. Do not treat a relation as a shortcut for granting access.

  ## What this domain owns

  * `Scope` — one node in the containment tree.
  * `ScopeRelation` — a lateral link between two scopes.
  * `RoleGrant` — one peer's role at one scope, allow or deny, propagating or not.

  Every resource here is tenanted on `account_id`, and the database enforces the
  same Account wall again with row-level security. A path is unique per Account,
  never globally.
  """

  use Ash.Domain

  resources do
    resource Cartulary.Topology.Scope
    resource Cartulary.Topology.ScopeRelation
    resource Cartulary.Topology.RoleGrant
  end
end

defmodule Cartulary.Topology.Scope do
  @moduledoc """
  One node in an Account's containment tree — a team, a project, a person's own space.

  A scope is addressed by its `path`: the full slash-delimited address from the
  root, such as `/team/project`. The path is the load-bearing field. Containment
  is decided by string prefix on it rather than by walking `parent_id`, which is
  why the path is written once at creation and no action accepts a change to
  it. Renaming a scope by rewriting its path would silently re-parent
  everything attached to it and to its descendants; create a new scope and move
  the work instead.

  Scopes are created lazily. Callers do not allocate them up front: ingesting an
  observation at `/team/project` creates every missing segment along the way,
  outermost first, and repeated ingest reuses the existing rows. That is why the
  create action is an idempotent upsert — it must be safe to retry and safe for
  two concurrent requests to race.

  `key` is the final segment and `name` a human label; both are cosmetic
  compared to the path. `state` marks the scope's own lifecycle and defaults to
  `"active"`. Nothing filters retrieval on it today, so setting it to anything
  else records an intention rather than hiding the scope's contents — do not
  rely on it as an access control.
  """

  use Cartulary.Resource, domain: Cartulary.Topology, table: "scopes"

  # One Account per row, enforced again in the database by row-level security.
  # A path is unique within an Account, never across Accounts.
  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    read :read do
      primary? true
    end

    # Idempotent creation keyed on the path, used while walking a path segment
    # by segment during ingest. A repeat only refreshes the label and state; the
    # parent link and the path itself stay as first written, because containment
    # is already derived from them.
    create :ensure do
      accept [:parent_id, :key, :name, :path, :state]
      upsert? true
      upsert_identity :unique_path
      upsert_fields [:name, :state, :updated_at]
    end

    # Relabelling and lifecycle only. `path` and `parent_id` are absent on
    # purpose: they define containment for every row that references this scope.
    update :update do
      accept [:name, :state]
    end
  end

  policies do
    # Account isolation applies to every action, including internal ones.
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    # A caller sees only the scopes its role grants resolved to. The scope's own
    # primary key is the column being matched here, since this *is* the scope.
    policy action_type(:read) do
      authorize_if {Cartulary.Policy.ScopeAccess, attribute: :id}
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false

    # The enclosing scope; nil at the root. Convenient for walking upward, but
    # containment questions are answered from `path`.
    attribute :parent_id, :uuid, public?: true

    # Final path segment.
    attribute :key, :string, allow_nil?: false, public?: true
    attribute :name, :string, allow_nil?: false, public?: true

    # Full address from the root. Inheritance, nearest-wins overrides, and
    # propagating role grants are all computed from this string.
    attribute :path, :string, allow_nil?: false, public?: true
    attribute :state, :string, allow_nil?: false, default: "active", public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    # Backs the upsert and guarantees one row per path. Tenant-scoped, so the
    # database index is on (account_id, path) and two Accounts may both have
    # a `/team`.
    identity :unique_path, [:path]
  end
end

defmodule Cartulary.Topology.ScopeRelation do
  @moduledoc """
  A lateral link between two scopes that are not in a parent-child line.

  Containment already connects a scope to its ancestors and descendants. This
  resource records the other kind of connection — two teams working on the same
  thing, a project related to a client — so retrieval can consider material
  from a neighbouring scope when the caller is entitled to both.

  **A relation grants nothing.** Retrieval expansion across a link happens only
  when both endpoints are already in the caller's authorized scope set, and the
  read policy on this resource enforces the same rule for the relation rows
  themselves. If a link could widen access, creating one would become a way to
  reach into someone else's scope, so never use one as a substitute for a role
  grant.

  In practice a relation is undirected: expansion matches a scope on either end
  and pulls in the other. Source and target order therefore records how the
  link was written, not a direction of flow — but it does affect uniqueness, so
  writing the mirror image creates a second row rather than colliding with the
  first.
  """

  use Cartulary.Resource, domain: Cartulary.Topology, table: "scope_relations"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    create :create do
      accept [:source_scope_id, :target_scope_id, :kind, :metadata]
    end

    # The endpoints cannot be edited: repointing a link would change which
    # scopes retrieval may bridge without leaving any trace of the old pair.
    update :update do
      accept [:kind, :metadata]
    end
  end

  policies do
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    # Both endpoints must be authorized. Seeing one side of a link never
    # entitles a caller to learn about the other.
    policy action_type(:read) do
      authorize_if {Cartulary.Policy.ScopeRelationAccess,
                    source_attribute: :source_scope_id, target_attribute: :target_scope_id}
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :source_scope_id, :uuid, allow_nil?: false, public?: true
    attribute :target_scope_id, :uuid, allow_nil?: false, public?: true

    # What kind of link this is. Part of the uniqueness key, so the same pair of
    # scopes may carry several differently-kinded links.
    attribute :kind, :string, allow_nil?: false, default: "related", public?: true

    # Free-form bookkeeping. Not public: it is never accepted from, or returned
    # to, an external caller.
    attribute :metadata, :map, allow_nil?: false, default: %{}
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    # One link per ordered pair and kind, so re-recording the same relation
    # fails rather than accumulating duplicates that would double-count during
    # retrieval expansion.
    identity :unique_relation, [:source_scope_id, :target_scope_id, :kind]
  end
end

defmodule Cartulary.Topology.RoleGrant do
  @moduledoc """
  One peer's role at one scope: allowed or denied, inherited downward or not.

  These rows are the raw material of authorization. They are not consulted per
  query — when a caller authenticates, every grant belonging to that peer is
  read once and folded into the concrete set of scopes it may act in, together
  with the effective role at each. Two rules govern that fold:

  * **Inheritance is downward and opt-in per grant.** A grant with `propagate`
    set reaches every scope contained in the one it was written at; without it
    the grant applies to that scope alone. A grant never reaches upward.
  * **Deny wins.** If any grant that reaches a scope has effect `"deny"`, the
    peer loses that scope entirely. A deny is not compared against allows and
    is not out-ranked by a stronger role, which is what lets an administrator
    cut a hole in a broad inherited grant and be certain nothing patches over
    it. The uniqueness key deliberately includes `effect`, so an allow and a
    deny for the same role at the same scope can coexist — and the deny wins.

  `role` holds a string: `"reader"`, `"member"`, `"curator"`, or
  `"account-admin"`, in increasing power (the underscore spelling of the last
  one is also accepted). Among surviving allows the strongest wins, and an
  unrecognised role string is ignored rather than guessed at, so a typo grants
  nothing instead of granting something arbitrary.

  Because grants are folded at authentication time, editing a row does not
  change an authorization context that has already been handed out. Anything
  that must see a fresh grant immediately re-resolves rather than reusing a
  cached context.
  """

  use Cartulary.Resource, domain: Cartulary.Topology, table: "role_grants"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    create :create do
      accept [
        :scope_id,
        :peer_id,
        :role,
        :effect,
        :propagate,
        :granted_by_peer_id,
        :granted_at
      ]
    end

    # The subject of a grant cannot be edited. Changing `scope_id` or `peer_id`
    # would move an existing grant to a different person or place while keeping
    # its original "granted by" evidence, which would make the audit trail lie.
    update :update do
      accept [:role, :effect, :propagate]
    end

    # The only destroy, and it exists for erasing a peer: removing someone means
    # removing the grants that named them. There is no administrator-facing
    # delete — revoking authority is an update that flips the grant to a deny,
    # which keeps the decision visible. Non-atomic so it runs record by record
    # over the rows the erasure walk selected.
    destroy :erase do
      require_atomic? false
    end
  end

  policies do
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    # Grants are visible where the caller can already see the scope; this does
    # not restrict the listing to the caller's own grants.
    policy action_type(:read) do
      authorize_if {Cartulary.Policy.ScopeAccess, attribute: :scope_id}
    end

    # Only an Account administrator *at that scope* may change authority there,
    # so administering one subtree never becomes authority to administer
    # another. Internal `:system` actors pass this check by definition.
    policy action_type([:create, :update, :destroy]) do
      authorize_if {Cartulary.Policy.ScopeRole, attribute: :scope_id, roles: [:account_admin]}
    end

    # Every applicable policy must pass, so this narrows destroys further rather
    # than offering an alternative route: `:erase` additionally demands the
    # internal pipeline flag. An Account administrator cannot call it, and the
    # erasure actor satisfies the rule above by carrying the `:system` role.
    policy action(:erase) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :scope_id, :uuid, allow_nil?: false, public?: true
    attribute :peer_id, :uuid, allow_nil?: false, public?: true
    attribute :role, :string, allow_nil?: false, public?: true

    # "allow" or "deny". A deny that reaches a scope removes it outright.
    attribute :effect, :string, allow_nil?: false, default: "allow", public?: true

    # Whether this grant reaches the scopes contained in `scope_id`. Defaults to
    # true, so a grant written high in the tree covers the subtree unless the
    # grantor says otherwise.
    attribute :propagate, :boolean, allow_nil?: false, default: true, public?: true

    # Who granted it and when: the durable evidence for an authority decision.
    attribute :granted_by_peer_id, :uuid, public?: true
    attribute :granted_at, :utc_datetime_usec, allow_nil?: false, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    # `effect` is part of the key on purpose: the same peer may hold both an
    # allow and a deny for one role at one scope, and the deny is what takes
    # effect.
    identity :unique_grant, [:scope_id, :peer_id, :role, :effect]
  end
end
