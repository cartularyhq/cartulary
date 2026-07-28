# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Resource do
  @moduledoc """
  The shared definition every durable Cartulary resource is built from.

  Using this module instead of `Ash.Resource` directly is what makes the
  guarantees below uniform rather than per-resource good intentions. It fixes
  the data layer to PostgreSQL through the single application repository,
  always installs the policy authorizer — so a resource can never accidentally
  ship without authorization — and gives every resource the two private actions
  that whole-Account export and import are built on.

  ## What it installs

  * `postgres` — the resource's table, on `Cartulary.Repo`. There is one
    repository in every deployment mode, so a resource never chooses a database.
  * `portability_export` — a keyset-paginated read used to stream every row of
    one Account out in bounded batches. Keyset paging is required for that:
    offset paging over a table being written to can skip or repeat rows, which
    would silently corrupt an archive.
  * `portability_import` — a create that restores a previously exported row
    verbatim, including its original primary key and timestamps.
  * A policy restricting both actions to internal actors.

  ## Why the import action looks unsafe

  `portability_import` accepts no attributes in the ordinary sense. It takes a
  single `:attributes` map and force-writes each known attribute onto the
  changeset. That deliberately bypasses the accept lists, defaults, and
  validations that normally protect a resource, because an archive restore must
  reproduce the original rows exactly — same ids, same belief and valid times,
  same lifecycle history — rather than create new ones. Unknown keys in the map
  are ignored rather than raising, so an archive written by an older build
  restores instead of failing on a since-removed column.

  That is why both actions are marked non-public (they are unreachable from any
  generated HTTP or MCP route) and are authorized only for the internal
  pipeline actor or the non-grantable `:system` role. No externally
  authenticated caller can ever hold either. Do not relax that policy, and do
  not call these actions to "fix up" a row: an ordinary update action exists for
  every mutation that is legal outside a restore.

  ## Options

  * `:domain` — the Ash domain this resource belongs to. Required.
  * `:table` — the PostgreSQL table name. Required.
  * `:extensions` — extra Ash extensions, such as job triggers or
    authentication. Defaults to none.

  Resources still declare their own multitenancy, policies, attributes, and
  actions; those blocks merge with the ones added here. Every resource but one
  is tenanted on `account_id` and repeats the Account check in its own policy
  block — this module does not add that check, because the Accounts row itself
  has no Account column to match on.
  """

  @doc """
  Declares the calling module as a Cartulary Ash resource.

  Injects the PostgreSQL data layer, the policy authorizer, the private
  portability export/import actions, and the policy that limits them to
  internal actors. Raises at compile time when `:domain` or `:table` is
  missing.
  """
  defmacro __using__(opts) do
    domain = Keyword.fetch!(opts, :domain)
    table = Keyword.fetch!(opts, :table)
    extensions = Keyword.get(opts, :extensions, [])

    quote do
      use Ash.Resource,
        otp_app: :cartulary,
        domain: unquote(domain),
        data_layer: AshPostgres.DataLayer,
        authorizers: [Ash.Policy.Authorizer],
        extensions: unquote(extensions)

      postgres do
        table unquote(table)
        repo Cartulary.Repo
      end

      actions do
        # Streams one Account's rows for a logical archive. Keyset pagination is
        # what makes a long export consistent under concurrent writes; it is
        # optional here only so an internal caller may read a small resource in
        # one shot.
        read :portability_export do
          public? false

          pagination do
            keyset? true
            required? false
          end
        end

        # Restores an archived row exactly as it was. Nothing is accepted
        # through the normal attribute path: the change force-writes the values
        # from the `:attributes` map so ids, timestamps, and history survive the
        # round trip. Internal actors only.
        create :portability_import do
          public? false
          accept []
          argument :attributes, :map, allow_nil?: false
          change Cartulary.Portability.Changes.RestoreAttributes
        end
      end

      policies do
        # Export and import can read and write anything in the Account, so they
        # are reachable only by the internal pipeline actor or the `:system`
        # role, neither of which any authenticated external caller can obtain.
        policy action([:portability_export, :portability_import]) do
          authorize_if actor_attribute_equals(:pipeline?, true)
          authorize_if {Cartulary.Policy.RoleIn, roles: [:system]}
        end
      end
    end
  end
end

defmodule Cartulary.Policy.ScopeAccess do
  @moduledoc """
  Narrows a read to the scopes the caller is actually allowed to see.

  This is the workhorse read guard for every resource that carries a scope
  column. It is a *filter* check, not a yes/no check: unauthorized rows are
  removed from the query rather than turned into a forbidden error. That is
  deliberate, and callers depend on it — a search over a partly-authorized set
  of scopes must return the permitted subset, and the absence of a row must not
  reveal that a row exists somewhere the caller cannot see.

  An actor whose `scope_ids` is `:all` passes everything. That value is
  reserved for internal server-side work; an actor built from an authenticated
  request always carries an explicit list, and an empty list matches nothing.
  Any actor shape without a `scope_ids` field — including `nil` for an
  unauthenticated caller — is refused outright.

  Pass `attribute:` when the scope lives under a different column name; it
  defaults to `:scope_id`. This check tests scope membership only. It says
  nothing about Account isolation, which every resource enforces separately,
  nor about what the caller may *do* in those scopes.
  """

  use Ash.Policy.FilterCheck

  # Policy descriptions surface in authorization explanations, so they name
  # the rule and never any row content.
  @impl true
  def describe(opts), do: "actor may read the #{opts[:attribute] || :scope_id} scope"

  @impl true
  def filter(%{scope_ids: :all}, _context, _opts), do: true

  def filter(%{scope_ids: scope_ids}, _context, opts) when is_list(scope_ids) do
    attribute = Keyword.get(opts, :attribute, :scope_id)
    expr(^ref(attribute) in ^scope_ids)
  end

  # Fail closed: an actor that does not carry a resolved scope list gets nothing.
  def filter(_actor, _context, _opts), do: false
end

defmodule Cartulary.Policy.RoleIn do
  @moduledoc """
  Passes when the caller's single strongest role is one of the listed roles.

  Use this for Account-wide actions — administering model roles, retrieval
  profiles, usage records — where the decision does not depend on which scope a
  row sits in. The role checked is the highest one the caller holds *anywhere*
  in the Account, so this check is deliberately coarse: it will admit an
  administrator of one corner of the tree to an Account-level action. Anything
  whose answer should differ per scope must use a per-scope check instead.

  `:system` may appear in the list and marks internal server-side work. It is
  not a grantable role, so no authenticated caller can ever satisfy a check
  that lists only `:system`.

  Being a simple check, this one produces a forbidden error rather than
  quietly filtering rows away. Raises when the `:roles` option is missing,
  which surfaces a mis-declared policy at the first request instead of silently
  authorizing.
  """

  use Ash.Policy.SimpleCheck

  @impl true
  def describe(opts), do: "actor role is one of #{inspect(Keyword.fetch!(opts, :roles))}"

  @impl true
  def match?(%{role: role}, _context, opts), do: role in Keyword.fetch!(opts, :roles)

  # No role field at all (an unauthenticated or malformed actor) never matches.
  def match?(_actor, _context, _opts), do: false
end

defmodule Cartulary.Policy.HumanRoleIn do
  @moduledoc """
  Passes only for a human session that also holds one of the listed roles.

  This is the check that keeps curator work human. Approving, editing,
  rejecting, merging, deferring, and promoting knowledge, and administering the
  rules that decide those outcomes, are decisions a person must make. A machine
  credential must never be able to approve its own submissions into shared
  memory, no matter how privileged the credential is.

  The human test is the *kind* of credential presented: only a session
  established by password login counts. An API key is refused even when the
  peer behind it genuinely holds the curator or administrator role, and even
  when a `:system` actor would otherwise sail through. Do not add a machine
  identity kind to this check to unblock automation — automation submits raw
  observations and lets governance decide.

  Raises when the `:roles` option is missing.
  """

  use Ash.Policy.SimpleCheck

  @impl true
  def describe(opts),
    do: "authenticated human actor has one of #{inspect(Keyword.fetch!(opts, :roles))}"

  @impl true
  def match?(%{identity_kind: :password, role: role}, _context, opts),
    do: role in Keyword.fetch!(opts, :roles)

  # Anything that is not a password-backed session — API keys, internal system
  # actors, no actor at all — fails, regardless of role.
  def match?(_actor, _context, _opts), do: false
end

defmodule Cartulary.Policy.HumanScopeRole do
  @moduledoc """
  Passes for a human session holding one of the listed roles *at the row's own scope*.

  Where the coarse role check asks "is this caller a curator anywhere", this one
  asks "is this caller a curator here". It matches the row's scope column
  against the per-scope role map the caller's grants resolved to, so authority
  over one part of the tree never becomes authority over another. A scope
  missing from that map is unauthorized — either no grant reached it or a deny
  removed it — and there is no separate negative entry to consult.

  Like the other filter checks it narrows the result set rather than raising, so
  a bulk action silently applies to the rows the caller may act on. As with the
  coarse human check, only a password-backed session qualifies; an API key
  never does.

  Pass `attribute:` for a differently named scope column; it defaults to
  `:scope_id`. Raises when `:roles` is missing.
  """

  use Ash.Policy.FilterCheck

  @impl true
  def describe(opts),
    do: "authenticated human has a permitted role at #{opts[:attribute] || :scope_id}"

  @impl true
  def filter(%{identity_kind: :password, scope_roles: scope_roles}, _context, opts)
      when is_map(scope_roles) do
    attribute = Keyword.get(opts, :attribute, :scope_id)
    roles = Keyword.fetch!(opts, :roles)

    scope_ids =
      for {scope_id, role} <- scope_roles,
          role in roles,
          do: scope_id

    expr(^ref(attribute) in ^scope_ids)
  end

  def filter(_actor, _context, _opts), do: false
end

defmodule Cartulary.Policy.HumanOwns do
  @moduledoc """
  Passes for a human session acting on a row that is about that same person.

  Some decisions belong to the subject and to nobody else — consenting to
  personal knowledge being promoted upward is the case this exists for. No
  amount of curator or administrator authority substitutes for the subject's
  own answer, so this check compares the row's subject column against the
  authenticated peer id and admits nothing else.

  Only a password-backed session qualifies. An API key issued to that same peer
  does not, because an agent holding a person's credential is not that person
  giving consent.

  Pass `attribute:` for a differently named subject column; it defaults to
  `:subject_peer_id`. Being a filter check, non-matching rows disappear from the
  query rather than raising.
  """

  use Ash.Policy.FilterCheck

  @impl true
  def describe(opts),
    do: "authenticated human owns #{opts[:attribute] || :subject_peer_id}"

  @impl true
  def filter(%{identity_kind: :password, peer_id: peer_id}, _context, opts)
      when is_binary(peer_id) do
    attribute = Keyword.get(opts, :attribute, :subject_peer_id)
    expr(^ref(attribute) == ^peer_id)
  end

  def filter(_actor, _context, _opts), do: false
end

defmodule Cartulary.Policy.ScopeRelationAccess do
  @moduledoc """
  Passes only when the caller is authorized at *both* ends of a cross-scope link.

  A relation row connects two scopes that are not in a parent-child line. The
  rule it must never break is that a link does not confer access: being allowed
  to see one side tells you nothing about the other, and following a link may
  never widen what a caller can reach. Requiring both endpoint scope ids to be
  in the caller's authorized set is how that is enforced at the row level, so
  retrieval expansion across links cannot leak the far side.

  An actor whose `scope_ids` is `:all` — internal server-side work only — sees
  every relation. Any actor without a resolved scope list sees none.

  Both `:source_attribute` and `:target_attribute` are required; there is no
  default, because guessing the wrong column here would check one endpoint
  twice and leave the other unguarded.
  """

  use Ash.Policy.FilterCheck

  @impl true
  def describe(_opts), do: "actor may read both ends of the scope relation"

  @impl true
  def filter(%{scope_ids: :all}, _context, _opts), do: true

  def filter(%{scope_ids: scope_ids}, _context, opts) when is_list(scope_ids) do
    source_attribute = Keyword.fetch!(opts, :source_attribute)
    target_attribute = Keyword.fetch!(opts, :target_attribute)

    expr(
      ^ref(source_attribute) in ^scope_ids and
        ^ref(target_attribute) in ^scope_ids
    )
  end

  def filter(_actor, _context, _opts), do: false
end

defmodule Cartulary.Policy.ScopeRole do
  @moduledoc """
  Passes when the caller holds one of the listed roles at the row's own scope.

  This is the write-side counterpart to the scope read filter: it authorizes
  acting on a row based on the caller's effective role *there*, not on the
  strongest role held somewhere else in the tree. Effective roles already have
  containment inheritance and deny-wins applied when the caller was
  authenticated, so a role granted higher up reaches this row only if that
  grant was marked to propagate, and any applicable deny has already removed
  the scope from the map entirely.

  Unlike the human-only variants this accepts machine credentials, so it is for
  work an agent may legitimately do — recording observations, for example — not
  for curator decisions. Internal `:system` actors bypass the scope map
  entirely.

  Pass `attribute:` for a differently named scope column; it defaults to
  `:scope_id`. Raises when `:roles` is missing.
  """

  use Ash.Policy.FilterCheck

  @impl true
  def describe(opts), do: "actor has a permitted role at #{opts[:attribute] || :scope_id}"

  @impl true
  def filter(%{role: :system}, _context, _opts), do: true

  def filter(%{scope_roles: scope_roles}, _context, opts) when is_map(scope_roles) do
    attribute = Keyword.get(opts, :attribute, :scope_id)
    roles = Keyword.fetch!(opts, :roles)

    scope_ids =
      for {scope_id, role} <- scope_roles,
          role in roles,
          do: scope_id

    expr(^ref(attribute) in ^scope_ids)
  end

  def filter(_actor, _context, _opts), do: false
end
