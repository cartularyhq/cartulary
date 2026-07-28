# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.GovernanceLive.Index do
  @moduledoc """
  The curator's review surface at `/governance`: the open gate queue, the human
  decisions taken on it, and skill-requirement-card authoring.

  ## Every decision here is human-only, by construction

  Nothing on this page may ever be driven by a machine credential. Three
  independent barriers enforce that, and all three must stay in place:

  1. **Session.** The route sits behind a browser password session. A curator
     signs in at `/governance/sign-in`; the live-session mount hook then admits
     the socket only when the authenticated actor is a password identity
     holding the account-admin or curator role. An API key cannot establish
     that session, so an agent cannot reach this LiveView at all.
  2. **Operation layer.** The governance operation layer re-checks the actor
     before it mutates anything and refuses a non-password or under-privileged
     one. A socket that somehow mounted without a human identity would still be
     rejected at the write.
  3. **Absent surface.** The tool set published to agents deliberately has no
     curator operations in it. Agents may submit raw observations, read
     governed memory, resolve the calling peer's own frozen question, and lower
     that peer's own interruption limits. Approve, edit, reject, merge, defer,
     promotion, gate-rule administration, bulk decisions, and card authoring
     are not exposed to them and must not be added.

  ## What this module owns

  Rendering and dispatch, nothing else. It contains no gate logic, computes no
  lifecycle state, and performs no durable write of its own. Each event
  forwards to the governance operation layer or to skill-card authoring, and
  those own the transaction, the advisory lock, the immutable decision record,
  the lifecycle event, and the hash-chained audit entry. Introducing a direct
  `Ash.create!`/`Ash.update!` here would put a second writer behind the gate
  and break the rule that reasoned knowledge is only ever written by the
  pipeline — never do it.

  ## Reading rules

  All reads run inside one Account-scoped transaction that sets the tenant the
  database's row-level security checks, so a curator can only ever load rows
  belonging to their own Account. Do not add tenancy filtering in the template:
  by the time data reaches the markup it is already filtered, and a
  template-level guard would mask a query that had lost its tenant.

  After every mutation the page re-reads the whole queue instead of patching
  assigns in memory. That keeps the rendered state identical to committed state
  and makes a bulk run that failed part-way immediately visible.

  ## Content safety

  This page renders knowledge statements on purpose: an authorized human has to
  read a claim in order to judge it. That text is for the browser only. Never
  copy a statement, an edited replacement, or card content into logs,
  telemetry, audit metadata, or background-job arguments — those channels carry
  ids, hashes, counts, states, and error classes only.
  """

  use CartularyWeb, :live_view

  alias Cartulary.DataLayer
  alias Cartulary.Governance.Engine
  alias Cartulary.Governance.ValidationItem
  alias Cartulary.Knowledge.KnowledgeItem
  alias Cartulary.Skills
  alias Cartulary.Skills.SkillRequirementCard
  alias Cartulary.Topology.Scope

  require Ash.Query

  @doc """
  Loads the queue for the curator who just signed in.

  There is no authorization check here on purpose. The live-session mount hook
  has already verified the session token, the password identity kind, and the
  account-admin/curator role, and has assigned the resulting actor; it
  redirects to sign-in rather than letting an unauthorized socket reach this
  callback. Do not add a fallback that tolerates a missing `current_actor` —
  that would turn a hard authentication failure into a silent partial page.
  """
  @impl true
  def mount(_params, _session, socket) do
    {:ok, load_queue(socket)}
  end

  @doc """
  Handles the three curator gestures available on this page.

  ## `"decide"` — one human decision on one queued item

  Requires the queue row id and an `action` of `approve`, `reject`, `defer`,
  `edit`, or `merge`. What each one changes downstream:

  - `approve` marks the knowledge `active` with a curator-approved
    verification, and when the queue row targets a wider scope the knowledge
    row is relocated to that scope. One case does not activate: personal
    knowledge being promoted to a scope parks at `awaiting_consent` and neither
    activates nor moves, because only the subject of that knowledge can grant
    target-specific consent. A curator approval is never a substitute for it.
  - `reject` moves the knowledge to `rejected`.
  - `defer` only pushes the queue row's due date out (24 hours unless
    `defer_hours` overrides it). The knowledge state is untouched.
  - `edit` does **not** rewrite the statement in place. It mints a new
    pipeline-owned knowledge row carrying the corrected `statement`, supersedes
    the original, and sends the replacement back through the gate from
    `proposed`. That keeps the pipeline the only writer of knowledge and leaves
    the original intact for audit.
  - `merge` folds this item's confidence, corroboration count, and source
    message ids into the knowledge row named by `merge_into_id`, then
    supersedes this item so the combined evidence survives on one row.

  Each of them writes an immutable decision record, a content-safe hash-chain
  audit event, and a lifecycle event wherever a state actually changed.

  ## `"bulk"` — the same decision applied to every checked row

  ## `"publish_skill_card"` — authors a new skill requirement card version

  Failure handling differs between the two families. Decisions raise rather
  than return on a forbidden actor, an unknown id, a blank edited statement, or
  a missing merge target; nothing is rescued here, so the LiveView process
  crashes and the client remounts onto freshly read state. Card publishing
  reports its errors as flash messages instead, because they are ordinary
  mistakes in a hand-edited form.
  """
  @impl true
  def handle_event("decide", %{"id" => id, "action" => action} = params, socket) do
    # Only the optional decision inputs are forwarded, and blank ones are
    # dropped rather than passed through as empty strings. The operation layer
    # reads an absent key as "keep what is stored" (sensitivity, defer window)
    # and requires a present one for edit and merge, so a blank field must
    # arrive as absent: passing "" would either overwrite a real value with
    # nothing or record an empty statement.
    opts =
      params
      |> Map.take(["statement", "merge_into_id", "defer_hours", "sensitivity"])
      |> Map.reject(fn {_key, value} -> value in [nil, ""] end)

    Engine.decide(socket.assigns.current_actor, id, action, opts)
    {:noreply, load_queue(socket)}
  end

  # Two shapes reach the same decision. The per-item buttons send the queue row
  # under `id`; the edit and merge forms send it under `validation_id`, which
  # names what the hidden field is so it is not mistaken for the knowledge id
  # sitting next to it in the same form. Renaming the key here keeps one
  # decision path rather than two that can drift apart. This clause must stay
  # adjacent to the one it delegates to: Elixir requires all clauses of a
  # function to be contiguous.
  def handle_event(
        "decide",
        %{"validation_id" => id, "action" => _action} = params,
        socket
      ) do
    handle_event("decide", Map.put(params, "id", id), socket)
  end

  # Each row's checkbox lives in the row markup but is bound to the toolbar
  # form by id, so the browser submits the selection as a map keyed by queue
  # row id. Only checked boxes are sent, and a run with nothing checked omits
  # the key entirely — hence the empty-map default and the no-op that follows.
  #
  # The operation layer applies these one at a time, each in its own
  # transaction under its own advisory lock. There is no all-or-nothing bulk
  # semantic: a failure part-way through leaves the earlier decisions
  # committed, which is exactly why the queue is re-read afterwards instead of
  # optimistically clearing the selected rows.
  def handle_event("bulk", %{"action" => action} = params, socket) do
    ids = params |> Map.get("ids", %{}) |> Map.keys()
    Engine.bulk_decide(socket.assigns.current_actor, ids, action)
    {:noreply, load_queue(socket)}
  end

  # Skill requirement cards are authored configuration, not knowledge. A card
  # states which governed knowledge must already exist before an agent may run
  # a named skill. Cards are plain-versioned: they never pass the gate, they
  # are never extracted from a conversation, and a card can never satisfy
  # another card's requirement.
  #
  # Publishing is not an edit. It creates a new immutable version and
  # deactivates the previous active version for the same scope and skill key,
  # both in one Account-scoped transaction serialized by an advisory lock, so
  # two curators publishing the same card concurrently cannot produce two
  # active versions or a duplicated version number.
  #
  # Both error branches are user error in a hand-edited textarea, so they
  # surface as a flash and leave the queue untouched: malformed JSON, an
  # unknown or unauthorized scope path, a skill key that is not a lowercase
  # slug, or a requirement list the selector validator rejects (unknown keys,
  # duplicate requirement keys, out-of-range confidence, non-positive freshness
  # or corroboration limits).
  def handle_event("publish_skill_card", params, socket) do
    with {:ok, requirements} <- Jason.decode(params["requirements"]),
         {:ok, card} <-
           Skills.publish(socket.assigns.current_actor, %{
             scope_path: params["scope_path"],
             skill_key: params["skill_key"],
             description: params["description"],
             requirements: requirements
           }) do
      socket =
        socket
        |> put_flash(:info, "Published #{card.skill_key} version #{card.version}.")
        |> load_queue()

      {:noreply, socket}
    else
      {:error, %Jason.DecodeError{}} ->
        {:noreply, put_flash(socket, :error, "Requirements must be valid JSON.")}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, to_string(message))}
    end
  end

  @doc """
  Renders the open queue, the per-item decision controls, and the skill-card
  authoring form.

  Markup is intentionally plain: inline styles and no client-side JavaScript
  beyond the LiveView socket itself. The browser pipeline serves this page
  under a Content-Security-Policy that forbids inline script, so any control
  added here must work as a server round-trip rather than a script hook.
  """
  @impl true
  def render(assigns) do
    ~H"""
    <div style="font-family: system-ui; max-width: 1100px; margin: 2rem auto; padding: 0 1rem;">
      <header style="display:flex; align-items:center; justify-content:space-between;">
        <div>
          <h1>Governance queue</h1>
          <p>Gate A/B proposals, conflicts, consent holds, and lifecycle reviews.</p>
        </div>
        <%!--
        Sign-out is a real form POST, not a link, because it destroys server
        session state: the hidden _method turns the POST into the DELETE route,
        and the CSRF token is mandatory for every state-changing browser
        request here. A GET link would let a third-party page log the curator
        out, and worse, would set the precedent that curator state changes can
        travel by GET.
        --%>
        <form method="post" action="/governance/sign-out">
          <input type="hidden" name="_method" value="delete" />
          <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
          <button>Sign out</button>
        </form>
      </header>

      <%!--
      The bulk toolbar holds no checkboxes of its own. Each queue row's
      checkbox is attached to this form by id, which is what lets the selection
      live inside the row markup while still submitting here. Each button
      carries the same name with a different value, so the pressed button is
      what tells the handler which decision to apply to the selection.

      Note the omissions: there is no bulk edit and no bulk merge. Both need a
      per-item value a curator must actually look at, and neither is safe to
      apply blindly across a selection.
      --%>
      <form id="bulk-form" phx-submit="bulk">
        <div style="display:flex; gap:.5rem; margin:1rem 0;">
          <button name="action" value="approve">Approve selected</button>
          <button name="action" value="reject">Reject selected</button>
          <button name="action" value="defer">Defer selected</button>
        </div>
      </form>

      <p :if={@items == []}>The queue is clear.</p>

      <%!--
      One card per open queue row. The statement is shown in full because a
      curator cannot judge a claim they cannot read; this is the one channel
      where that text is allowed to appear. The metadata beside it is what the
      decision actually turns on — how confident the extraction was, how
      sensitive the claim is, how far the item wants to travel, which raw
      observations produced it, and which existing knowledge it contradicts.
      Provenance and conflict ids are rendered as opaque ids on purpose: they
      let a curator go look, without pulling more content onto the page.
      --%>
      <article
        :for={item <- @items}
        style="border:1px solid #d0d7de; border-radius:8px; padding:1rem; margin:1rem 0;"
      >
        <div style="display:flex; gap:.75rem; align-items:start;">
          <%!--
          Bound to the bulk toolbar above by form id. The name makes the
          browser submit the selection as a map keyed by queue row id, so the
          handler gets exactly the checked ids and nothing else.
          --%>
          <input
            type="checkbox"
            form="bulk-form"
            name={"ids[#{item.id}]"}
            value="true"
          />
          <div style="flex:1;">
            <p><strong>{item.knowledge.statement}</strong></p>
            <dl style="display:grid; grid-template-columns:10rem 1fr; gap:.25rem;">
              <dt>Gate / target</dt><dd>{item.kind} / {item.target_level}</dd>
              <dt>Confidence</dt><dd>{item.confidence}</dd>
              <dt>Sensitivity</dt><dd>{item.sensitivity}</dd>
              <dt>State / due</dt><dd>{item.state} / {item.due_at}</dd>
              <dt>Provenance IDs</dt><dd>{Enum.join(item.provenance_ids, ", ")}</dd>
              <dt>Conflicts</dt><dd>{Enum.join(item.conflict_knowledge_ids, ", ")}</dd>
            </dl>

            <%!--
            Approve, reject, and defer need no extra input, so they are direct
            clicks rather than forms. type="button" keeps them from ever being
            treated as a submit control if this markup is later moved inside a
            form; the decision must travel as this explicit event, never as an
            incidental form submission.
            --%>
            <div style="display:flex; flex-wrap:wrap; gap:.5rem; margin-top:1rem;">
              <button type="button" phx-click="decide" phx-value-id={item.id} phx-value-action="approve">
                Approve
              </button>
              <button type="button" phx-click="decide" phx-value-id={item.id} phx-value-action="reject">
                Reject
              </button>
              <button type="button" phx-click="decide" phx-value-id={item.id} phx-value-action="defer">
                Defer
              </button>
            </div>

            <%!--
            "Edit as replacement" is the literal behaviour, not a euphemism.
            Submitting does not overwrite the statement: it mints a new
            pipeline-owned knowledge row with the corrected text, supersedes
            this one, and runs the replacement through the gate from scratch.
            The curator supplies wording; the pipeline stays the only writer,
            and the original text remains recoverable through its history.
            The field is pre-filled with the current statement so a curator
            corrects rather than retypes, and a cleared field is dropped as
            blank rather than saved as an empty claim.
            --%>
            <form phx-submit="decide" style="display:flex; gap:.5rem; margin-top:.75rem;">
              <input type="hidden" name="validation_id" value={item.id} />
              <input type="hidden" name="action" value="edit" />
              <input name="statement" value={item.knowledge.statement} style="flex:1;" />
              <button>Edit as replacement</button>
            </form>

            <%!--
            Merge folds this item into an existing knowledge row: the target
            keeps the higher confidence, the summed corroboration count, and
            the union of source message ids, and this item is superseded. The
            target is typed as a raw knowledge id because the curator arrives
            here from the conflict ids listed above, which are the ids worth
            merging into.
            --%>
            <form phx-submit="decide" style="display:flex; gap:.5rem; margin-top:.75rem;">
              <input type="hidden" name="validation_id" value={item.id} />
              <input type="hidden" name="action" value="merge" />
              <input name="merge_into_id" placeholder="Knowledge ID to merge into" style="flex:1;" />
              <button>Merge</button>
            </form>
          </div>
        </div>
      </article>

      <%!--
      Skill requirement cards share this page because both are curator work,
      but they are a different kind of thing from the queue above. A card is
      authored configuration that says which governed knowledge must already
      exist before an agent may run a named skill. Cards are not knowledge:
      they never pass the gate, and one card can never satisfy another card's
      requirement. Card authoring exists here and nowhere else — agents get a
      readiness check, never a way to write the contract they are checked
      against.
      --%>
      <section style="border-top:2px solid #d0d7de; margin-top:2rem; padding-top:1.5rem;">
        <h2>Skill requirement cards</h2>
        <p>
          Author and review versioned procedural-memory contracts. Child scopes override
          inherited requirements by requirement key.
        </p>

        <form phx-submit="publish_skill_card" style="display:grid; gap:.75rem; margin:1rem 0;">
          <%!--
          Scope path rather than scope id: the path is what a curator can read
          and verify. It is resolved against the scopes this curator is
          authorized to see, so an unknown or unauthorized path is rejected
          with a message instead of silently creating a card somewhere else.
          --%>
          <label>
            Scope path
            <input name="scope_path" placeholder="/marketing/social" required style="width:100%;" />
          </label>
          <label>
            Skill key
            <input name="skill_key" placeholder="write-copy" required style="width:100%;" />
          </label>
          <label>
            Description
            <input name="description" placeholder="Knowledge needed before writing copy" style="width:100%;" />
          </label>
          <%!--
          "f9-1" is the pinned identity of the requirement-selector schema
          that is stored on every published card, so a reader of an old card
          knows which selector language it was written in. It is data, not a
          label: changing that string is a deliberate contract transition —
          every stored card and every consumer of a readiness report is written
          against it — and owes a changelog entry plus refreshed contract
          evidence. It is not a cosmetic version bump.

          The textarea is raw JSON on purpose. Requirements are a small
          declarative language (which knowledge kind, whose, how fresh, how
          confident, required versus preferred, and whether the peer may be
          asked), and a curator reviewing a contract should see the whole
          contract rather than a form that hides half of it.
          --%>
          <label>
            Requirements (`f9-1` JSON)
            <textarea name="requirements" rows="12" required style="width:100%;">{skill_card_example()}</textarea>
          </label>
          <button>Publish new version</button>
        </form>

        <p :if={@skill_cards == []}>No skill cards have been authored.</p>

        <%!--
        Every version is listed, newest first within each skill key, not just
        the active one: superseded versions are the record of what the contract
        used to demand, which is what makes an old readiness result readable
        after the fact. Exactly one version per scope and skill key is "active";
        the rest are marked retired and are never consulted by a readiness
        check. Requirements are printed verbatim so a reviewer compares the
        stored contract, not a re-rendering of it.
        --%>
        <article
          :for={card <- @skill_cards}
          style="border:1px solid #d0d7de; border-radius:8px; padding:1rem; margin:1rem 0;"
        >
          <p>
            <strong>{card.skill_key}</strong>
            · {card.scope_path}
            · version {card.version}
            · {card.requirement_schema_version}
            · {if(card.active, do: "active", else: "retired")}
          </p>
          <p :if={card.description}>{card.description}</p>
          <pre style="overflow:auto; white-space:pre-wrap;">{Jason.encode!(card.requirements, pretty: true)}</pre>
        </article>
      </section>
    </div>
    """
  end

  # Re-reads everything the page shows. Called on mount and again after every
  # mutation, because nothing here is patched in memory: the rendered page is
  # always committed state.
  #
  # All four queries run inside one Account-scoped transaction. That wrapper is
  # what sets the Account the database's row-level security checks, so a
  # curator physically cannot read another Account's rows even if a filter were
  # dropped. Never move a query out of it, and never rely on a template filter
  # to keep tenants apart.
  defp load_queue(socket) do
    {items, skill_cards} =
      DataLayer.with_actor(socket.assigns.current_actor, fn account, actor ->
        # Only states that still need something from a human are listed:
        # "pending" and "escalated" want a decision now, "deferred" is waiting
        # on a timer a curator set, and "awaiting_consent" is a curator
        # approval parked until the subject of personal knowledge grants
        # target-specific consent. Decided rows (approved, rejected, merged)
        # are history and belong in the audit trail, not the work queue.
        # Oldest due date first, so the most overdue review is on top.
        validations =
          ValidationItem
          |> Ash.Query.filter(state in ["pending", "deferred", "awaiting_consent", "escalated"])
          |> Ash.Query.sort(due_at: :asc)
          |> Ash.Query.set_tenant(account.id)
          |> Ash.read!(actor: actor)

        # The statement is fetched per row under the same actor rather than
        # joined onto the queue read. Authorization is then applied to the
        # knowledge itself, so a queue row can never carry content the curator
        # is not allowed to read. The extra round-trips are the price of that,
        # and the queue is short by design.
        #
        # `:knowledge` is a render-only key attached to the loaded struct. It
        # is not an attribute and is never written back.
        items =
          Enum.map(validations, fn item ->
            knowledge =
              KnowledgeItem
              |> Ash.Query.filter(id == ^item.knowledge_id)
              |> Ash.Query.set_tenant(account.id)
              |> Ash.read_one!(actor: actor)

            Map.put(item, :knowledge, knowledge)
          end)

        # Cards store a scope id, but a human recognises the path. Build the
        # lookup from the scopes this actor may read, so the same authorization
        # that hid a scope also keeps its path off the page.
        scope_paths =
          Scope
          |> Ash.Query.set_tenant(account.id)
          |> Ash.read!(actor: actor)
          |> Map.new(&{&1.id, &1.path})

        # Grouped by skill key with the newest version first, so the active
        # version of each skill heads its group and older ones read as history.
        #
        # The path lookup is deliberately strict. A card whose scope is absent
        # from the authorized map means this read returned a card from a scope
        # the curator cannot see, which is a tenancy or policy defect: failing
        # loudly is correct, and softening it to a default would render a
        # contract under the wrong scope.
        skill_cards =
          SkillRequirementCard
          |> Ash.Query.sort(skill_key: :asc, version: :desc)
          |> Ash.Query.set_tenant(account.id)
          |> Ash.read!(actor: actor)
          |> Enum.map(&Map.put(&1, :scope_path, Map.fetch!(scope_paths, &1.scope_id)))

        {items, skill_cards}
      end)

    socket
    |> assign(:items, items)
    |> assign(:skill_cards, skill_cards)
  end

  # Seeds the authoring textarea with one valid requirement so a curator can
  # see the shape of the selector language instead of guessing it. This is a
  # form default only: nothing here is stored, versioned, or enforced until
  # Publish is pressed.
  #
  # The example reads: before this skill runs, there must be governed
  # preference knowledge whose subject is the scope itself, revalidated within
  # 2_592_000 seconds (30 days, the freshness window brand guidance is assumed
  # to drift over). `"level" => "required"` means a missing or stale match
  # blocks the skill outright; "preferred" would only warn. `"either"` lets any
  # otherwise-matching governed statement satisfy it, rather than forcing a
  # fresh question to the peer.
  #
  # The prompt is the wording an agent uses if it does have to ask. An answer
  # to it is not knowledge: it must return through ordinary raw ingest, be
  # extracted, and pass the gate before readiness is rechecked. Neither this
  # page nor any client helper may turn an elicited answer into knowledge.
  defp skill_card_example do
    Jason.encode!(
      [
        %{
          "key" => "brand-voice",
          "description" => "Current brand voice",
          "selector" => %{"kind" => "preference", "subject" => "scope"},
          "level" => "required",
          "source_policy" => "either",
          "freshness" => %{"revalidated_within_seconds" => 2_592_000},
          "prompt" => "How should this scope's brand voice sound?"
        }
      ],
      pretty: true
    )
  end
end
