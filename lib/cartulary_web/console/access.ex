# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.Console.Access do
  @moduledoc """
  What a signed-in person may see and do in the browser console.

  Ash policies already decide two things before this module is consulted: which
  Account a row belongs to, and whether the caller's resolved role grants reach
  the scope the row lives in. Neither of those is re-implemented here. What Ash
  cannot express — because it is a property of the governance lifecycle rather
  than of tenancy — is which *lifecycle states* a given viewer should be shown,
  and which curator or subject gestures should be offered to them. That is what
  this module owns, and it owns it in one place so no page can quietly widen it.

  ## The two visibility rules

  1. **The provisional rule.** A `provisional` statement is visible only to the
     peer it is about. This applies to every viewer, including account
     administrators: `provisional` means "usable by one peer while a human
     decision is pending", not "nearly approved". The condition is
     `state != "provisional" or subject_peer_id == <viewer>`, which is exactly
     the condition the retrieval layer applies to every candidate query. The
     two must stay identical — if retrieval and the console disagree about
     provisional visibility, one of them is leaking.

  2. **The governance-state rule.** Curators and account administrators see
     every lifecycle state, because deciding what happens to `proposed`, `held`,
     and `contested` items is their job. Members and readers see only states
     that represent settled belief, plus anything at all whose subject is
     themselves — a person may always read what the system says about them, and
     that self-view is what makes contesting, redacting, and erasure possible.

  Both rules are *narrowing*. Neither can grant access to a scope the actor's
  role grants do not already reach.

  ## Action gating

  `can?/2` answers whether an actor may perform a console gesture. Every answer
  here is advisory: it decides whether a control is rendered, and nothing more.
  The operation layer re-checks the same authority before it writes, so a
  forged event from a hand-crafted client is refused there rather than here.
  Never treat a `true` from this module as authorization on its own, and never
  remove the operation-layer check because this module already ran.

  ## Mistakes to avoid

  Do not add a state to the settled list because a page looked empty in
  testing; an empty console for a reader with no active knowledge is the
  correct result. Do not special-case an actor's `role` without also checking
  `identity_kind` for any gesture that changes stored state — curator authority
  is human-only, and a machine credential holding a curator role must still be
  refused.
  """

  alias Cartulary.Actor

  # Lifecycle states a member or reader may see for knowledge that is not about
  # them. These are the states that represent something the system currently
  # believes, or used to believe and has retired in the open. Deliberately
  # absent: `proposed`, `held`, `provisional`, `rejected`, `contested`,
  # `redacted`, `stale`, and `retracted` — those are either undecided proposals
  # that have not passed a gate, or content withdrawn on purpose.
  @settled_states ~w(active needs_revalidation expired superseded)

  # Every state the knowledge lifecycle defines. Kept in step with the
  # `transition` action's validation list on the knowledge resource; a state
  # added there and not here would be invisible to curators in the console.
  @all_states ~w(
    proposed active provisional held needs_revalidation superseded
    expired rejected contested redacted stale retracted
  )

  # Roles whose holders govern the lifecycle rather than merely reading it.
  @governing_roles [:account_admin, :curator]

  @doc """
  Lifecycle states this actor may be shown for knowledge that is not about them.

  Returns every state for a curator or account administrator, and the settled
  subset for everyone else. The caller must still apply the provisional rule
  and the self-subject exemption; this list alone is not the whole filter, which
  is why `knowledge_filter_terms/1` exists and should be preferred.
  """
  def visible_states(%Actor{role: role}) when role in @governing_roles, do: @all_states
  def visible_states(%Actor{}), do: @settled_states

  @doc """
  Every lifecycle state the knowledge resource defines, oldest-to-newest in the
  order a statement typically travels.

  Used to populate filter controls, so a curator can ask for a state that
  happens to have no rows right now and get an honest empty result rather than
  an absent option.
  """
  def all_states, do: @all_states

  @doc """
  The two ingredients a knowledge query needs in order to be filtered correctly.

  Returns `{states, peer_id}`, where `states` is the list from
  `visible_states/1` and `peer_id` is the viewer's own peer id or `nil`.

  Callers must combine them as:

      state in states or subject_peer_id == peer_id     # governance-state rule
      and (state != "provisional" or subject_peer_id == peer_id)   # provisional rule

  A `nil` peer id means the subject branches must be dropped entirely rather
  than compared against `nil`. Comparing `subject_peer_id` to `nil` in SQL
  becomes `IS NULL`, which would match every statement that is about nobody —
  the opposite of narrowing. Console actors always carry a peer id because the
  mount hook admits only password identities, but the `nil` case is stated here
  so a future caller outside that hook cannot get it wrong by accident.
  """
  def knowledge_filter_terms(%Actor{} = actor), do: {visible_states(actor), actor.peer_id}

  @doc """
  Whether one already-loaded knowledge row should be shown to this actor.

  This is the in-memory twin of `knowledge_filter_terms/1`, for the handful of
  places that receive rows from an operation-layer call rather than building
  their own query — the retrieval search results and the governance history
  bundle. Prefer filtering in the query when there is a query to filter.
  """
  def visible_knowledge?(%Actor{} = actor, item) do
    own_subject? = not is_nil(actor.peer_id) and item.subject_peer_id == actor.peer_id

    provisional_ok? = item.state != "provisional" or own_subject?
    state_ok? = item.state in visible_states(actor) or own_subject?

    provisional_ok? and state_ok?
  end

  @doc """
  Whether `actor` may perform console gesture `action`.

  Recognised actions:

  - `:curate` — decide on a queued gate item (approve, reject, defer, edit as
    replacement, merge) and author skill requirement cards.
  - `:promote` — ask to move a statement up to a wider scope.
  - `:administer` — read the operations page: readiness, queue depth, usage and
    cost, gate rules, retrieval profiles.
  - `:self_govern` — confirm, contest, or redact a statement about oneself,
    answer a consent request, or request erasure.

  Every state-changing action additionally requires a password identity. A
  machine API key that somehow reached a console socket holds no curator
  authority no matter which role it resolved to, because approving knowledge is
  a decision a person takes. An unrecognised action returns `false` rather than
  raising, so a typo in a template hides a control instead of crashing a page.
  """
  def can?(%Actor{} = actor, :curate),
    do: human?(actor) and actor.role in @governing_roles

  def can?(%Actor{} = actor, :promote),
    do: human?(actor) and actor.role in @governing_roles

  def can?(%Actor{} = actor, :administer),
    do: human?(actor) and actor.role == :account_admin

  def can?(%Actor{} = actor, :self_govern),
    do: human?(actor) and is_binary(actor.peer_id)

  def can?(%Actor{}, _action), do: false

  @doc """
  Whether this actor is the subject of the given knowledge row, and may
  therefore confirm, contest, or redact it.

  Being the subject is independent of holding any role: a person with no grant
  on the scope a statement lives in may still act on a statement about
  themselves, which is precisely why this is a separate question from
  `can?/2`.
  """
  def subject_of?(%Actor{} = actor, item) do
    can?(actor, :self_govern) and item.subject_peer_id == actor.peer_id
  end

  @doc """
  Human-readable label for an actor's effective role, for the console header.

  The effective role is the highest one the actor holds anywhere in the
  Account, so it describes the ceiling of what they can do, not what they can
  do in the scope they happen to be looking at. Pages that offer a scope-
  specific gesture must consult the per-scope role instead.
  """
  def role_label(%Actor{role: :account_admin}), do: "Account admin"
  def role_label(%Actor{role: :curator}), do: "Curator"
  def role_label(%Actor{role: :member}), do: "Member"
  def role_label(%Actor{role: :reader}), do: "Reader"
  def role_label(%Actor{role: role}), do: to_string(role)

  @doc """
  The actor's effective role at one specific scope, or `nil` when no grant
  reaches it.

  A scope absent from the actor's `scope_roles` map is not authorized — either
  no grant applies, or a deny grant removed it. Deny always wins, so an absent
  entry must be read as "no access" and never softened to a default role.
  """
  def scope_role(%Actor{} = actor, scope_id), do: Map.get(actor.scope_roles, scope_id)

  # Curator, subject, and administrative gestures all change stored state, and
  # all of them are reserved for a person who signed in with a password. This
  # is checked separately from the role because the two are independent: an
  # agent credential can hold a high role and still must never drive any of
  # them.
  defp human?(%Actor{identity_kind: :password}), do: true
  defp human?(%Actor{}), do: false
end
