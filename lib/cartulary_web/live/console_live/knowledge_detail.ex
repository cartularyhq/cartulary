# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.ConsoleLive.KnowledgeDetail do
  @moduledoc """
  One statement in full, at `/console/knowledge/:id`: what it says, where it
  came from, how it got to its current state, what it is connected to, and what
  this reader may do about it.

  ## The page is the transparency surface

  Everything the system holds about a statement is on it: the four independent
  axes (subject against source, belief time against valid time, confidence
  against sensitivity, state against verification), the raw observations and
  document versions it was extracted from, the model and prompt identity that
  extracted it, the embedding identity attached to it, its lifecycle timeline,
  its relations in both directions, and the supersession chain it belongs to.
  A reader who cannot see why the system believes something cannot meaningfully
  govern it.

  ## What this module may write: nothing

  Every action forwards to the governance operation layer, which owns the
  transaction, the advisory lock, the immutable decision record, the lifecycle
  event, and the hash-chained audit entry. Introducing an `Ash.create!` or
  `Ash.update!` here would put a second writer behind the gate and break the
  rule that reasoned knowledge is only ever written by the pipeline. Do not do
  it, not even for a field that looks harmless.

  ## Who may do what

  Controls are rendered according to the reader's authority, and the operation
  layer re-checks that authority before it writes — a control that was never
  rendered is still refused if the event is forged. The split is:

  - **Curators and account administrators** decide queued items: approve,
    reject, defer, edit as a replacement, merge into another statement. They
    may also ask to promote a statement to a wider scope, which parks it for a
    second decision rather than moving it.
  - **The subject of a statement** may confirm, contest, or redact it,
    whatever role they hold and whichever scope the statement lives in. That is
    not a curator power and a curator cannot exercise it on someone's behalf.

  "Edit as replacement" is literal. It does not rewrite the statement: it mints
  a new pipeline-owned row with the corrected text, supersedes this one, and
  sends the replacement back through the gate. The original text stays
  readable, which is the whole point.

  ## Content safety

  The statement, the raw observations behind it, and any edited replacement are
  rendered here because an authorized human has to read them to judge them.
  That text is for the browser only. Never copy it into logs, telemetry, audit
  metadata, or job arguments — those channels carry ids, hashes, counts,
  states, and error classes.
  """

  use CartularyWeb, :live_view

  import CartularyWeb.ConsoleComponents

  alias Cartulary.Governance.Engine
  alias CartularyWeb.Console.Access
  alias CartularyWeb.Console.Loader

  @doc """
  Loads one statement, or renders the not-found state.

  A statement that exists but fails the console's lifecycle-state or
  provisional rule is reported as not found, exactly like an id that names
  nothing. The two must stay indistinguishable: a distinct "forbidden" would
  let a reader confirm the existence of proposals they are not entitled to see.
  """
  @impl true
  def mount(%{"id" => id}, _session, socket) do
    {:ok, load(socket, id)}
  end

  @doc """
  Applies one curator decision, one promotion request, or one subject verdict.

  All three raise rather than return on a refusal from the operation layer,
  which is where authority is actually enforced. Refusals and bad input are
  turned into a flash message rather than crashing the socket, because the
  merge target and the replacement statement are free-text fields a person
  types by hand and a typo is an ordinary mistake, not an exceptional
  condition. A genuinely forbidden action lands in the same branch and reports
  the same generic refusal; the write did not happen either way.

  After every attempt the page re-reads from the database instead of patching
  assigns in memory, so what is rendered is committed state and a partially
  applied change is immediately visible.
  """
  @impl true
  # Every clause below reads the loaded statement, so an event that arrives when
  # nothing is loaded — the not-found page, or a forged message — is answered
  # with a refusal rather than a crash. This clause has to come first: it is the
  # one that makes the others safe to write without repeating the check.
  def handle_event(_event, _params, %{assigns: %{detail: nil}} = socket) do
    {:noreply, put_flash(socket, :error, "That action was refused. Nothing was changed.")}
  end

  def handle_event("decide", %{"action" => action} = params, socket) do
    # Only the optional decision inputs are forwarded, and blank ones are
    # dropped rather than sent as empty strings. The operation layer reads an
    # absent key as "keep what is stored" for sensitivity and the defer window,
    # and requires a present one for edit and merge, so a cleared field must
    # arrive absent — passing "" would either overwrite a stored value with
    # nothing or record an empty claim.
    opts =
      params
      |> Map.take(["statement", "merge_into_id", "defer_hours", "sensitivity"])
      |> Map.reject(fn {_key, value} -> value in [nil, ""] end)

    # A decision acts on a queue row, not on the statement. When there is no
    # open row there is nothing to decide, and the controls were never
    # rendered — so this only happens for a forged event, which is refused
    # rather than allowed to raise on a nil id.
    case socket.assigns.detail.validation do
      nil ->
        {:noreply, put_flash(socket, :error, "There is no open decision on this statement.")}

      validation ->
        guard(socket, "Decision recorded.", fn actor ->
          Engine.decide(actor, validation.id, action, opts)
        end)
    end
  end

  def handle_event("promote", %{"target_scope_id" => target_scope_id}, socket) do
    id = socket.assigns.detail.item.id

    guard(socket, "Promotion requested. It is held until a second human decision.", fn actor ->
      Engine.request_promotion(actor, id, target_scope_id)
    end)
  end

  def handle_event("subject", %{"verdict" => verdict}, socket) do
    id = socket.assigns.detail.item.id

    guard(socket, "Recorded your verdict as the subject of this statement.", fn actor ->
      Engine.contest(actor, id, verdict)
    end)
  end

  @doc """
  Renders the statement, its evidence, its history, and the controls this
  reader is entitled to.
  """
  @impl true
  def render(%{detail: nil} = assigns) do
    ~H"""
    <.shell actor={@current_actor} active={:knowledge} title="Statement not found" flash={@flash}>
      <.panel title="Nothing here" description="This id names no statement you can read.">
        <p>
          An id that does not exist and an id you are not entitled to see are reported
          identically, so that neither can be used to probe for the other.
        </p>
        <p><.link navigate={~p"/console/knowledge"}>Back to the explorer</.link></p>
      </.panel>
    </.shell>
    """
  end

  def render(assigns) do
    ~H"""
    <.shell actor={@current_actor} active={:knowledge} title="Statement" flash={@flash}>
      <:subtitle>
        {@detail.item.scope_path || "(unreadable scope)"} · recorded {timestamp(
          @detail.item.inserted_at
        )}
      </:subtitle>

      <section class="statement-card">
        <p class="statement">{@detail.item.statement}</p>
        <div class="badge-row">
          <.badge family="state" value={@detail.item.state} />
          <.badge family="kind" value={@detail.item.kind} />
          <.badge family="sensitivity" value={@detail.item.sensitivity} />
          <.badge family="level" value={@detail.item.target_level} />
          <span class="badge">confidence {Float.round(@detail.item.confidence * 1.0, 2)}</span>
          <span class="badge">corroborated ×{@detail.item.corroboration_count}</span>
        </div>
      </section>

      <div class="split">
        <.panel
          title="Subject and source"
          description="Who the claim is about, and where it came from. These are independent: a colleague can be the subject of something you said."
        >
          <dl class="pairs">
            <dt>Subject peer</dt>
            <dd><.id_chip value={@detail.item.subject_peer_id} /></dd>
            <dt>Subject scope</dt>
            <dd><.id_chip value={@detail.item.subject_scope_id} /></dd>
            <dt>Source observations</dt>
            <dd>{length(@detail.item.source_message_ids)}</dd>
            <dt>Verification</dt>
            <dd>{@detail.item.verification}</dd>
            <dt>Held for scope</dt>
            <dd><.id_chip value={@detail.item.held_scope_id} /></dd>
          </dl>
        </.panel>

        <.panel
          title="Belief time and valid time"
          description="When the system holds the claim, against when the claim is true in the world. A fact can be freshly learned and long expired."
        >
          <dl class="pairs">
            <dt>Recorded</dt>
            <dd>{timestamp(@detail.item.inserted_at)}</dd>
            <dt>Revalidate after</dt>
            <dd>{timestamp(@detail.item.revalidate_after)}</dd>
            <dt>Expires</dt>
            <dd>{timestamp(@detail.item.expires_at)}</dd>
            <dt>Relevant from</dt>
            <dd>{timestamp(@detail.item.relevant_from)}</dd>
            <dt>Relevant until</dt>
            <dd>{timestamp(@detail.item.relevant_until)}</dd>
          </dl>
        </.panel>
      </div>

      <.panel
        title="How this was produced"
        description="The extraction and embedding identities travel with the statement, so a reader can tell which model produced it and whether its vector is still comparable."
      >
        <dl class="pairs wide">
          <dt>Extracted by</dt>
          <dd>
            {@detail.item.extracting_provider || "—"} / {@detail.item.extracting_model || "—"} / {@detail.item.extracting_model_version ||
              "—"}
          </dd>
          <dt>Prompt version</dt>
          <dd>{@detail.item.prompt_version || "—"}</dd>
          <dt>Pipeline version</dt>
          <dd>{@detail.item.pipeline_version}</dd>
          <dt>Embedding</dt>
          <dd>
            {@detail.item.embedding_provider || "not embedded"}
            <span :if={@detail.item.embedding_model}>
              / {@detail.item.embedding_model} / {@detail.item.embedding_version} / {@detail.item.embedding_dimensions}d
            </span>
          </dd>
        </dl>
      </.panel>

      <.panel
        :if={@actions.any?}
        title="Actions available to you"
        description="Each of these is carried out by the governance layer, which records an immutable decision and a hash-chained audit entry alongside the change."
      >
        <div :if={@actions.curate} class="action-group">
          <h3>Curator decision</h3>
          <p class="hint">
            This statement has an open queue entry
            (<.badge family="state" value={@detail.validation.state} />, due {timestamp(
              @detail.validation.due_at
            )}).
          </p>

          <div class="button-row">
            <%!--
              type="button" keeps these from being treated as submit controls
              if the markup is later moved inside a form. A decision must travel
              as this explicit event, never as an incidental form submission.
            --%>
            <button type="button" class="primary" phx-click="decide" phx-value-action="approve">
              Approve
            </button>
            <button type="button" phx-click="decide" phx-value-action="reject">Reject</button>
            <button type="button" phx-click="decide" phx-value-action="defer">Defer 24h</button>
          </div>

          <form phx-submit="decide" class="inline-form">
            <input type="hidden" name="action" value="edit" />
            <label class="grow">
              Corrected wording
              <input name="statement" value={@detail.item.statement} />
            </label>
            <button>Edit as replacement</button>
          </form>
          <p class="hint">
            Editing does not rewrite this statement. It mints a replacement carrying your
            wording, supersedes this one, and sends the replacement back through the gate.
            The original stays readable.
          </p>

          <form phx-submit="decide" class="inline-form">
            <input type="hidden" name="action" value="merge" />
            <label class="grow">
              Merge into statement id
              <input name="merge_into_id" placeholder="Paste a knowledge id from the conflicts below" />
            </label>
            <button>Merge</button>
          </form>
        </div>

        <div :if={@actions.promote} class="action-group">
          <h3>Promote to a wider scope</h3>
          <p class="hint">
            Promotion holds the statement at the target scope for a second human decision.
            Personal knowledge additionally waits for the subject's own consent, which a
            curator cannot give on their behalf.
          </p>
          <form phx-submit="promote" class="inline-form">
            <label class="grow">
              Target scope
              <select name="target_scope_id">
                <option :for={scope <- @actions.promotion_targets} value={scope.id}>
                  {scope.path}
                </option>
              </select>
            </label>
            <button>Request promotion</button>
          </form>
        </div>

        <div :if={@actions.subject} class="action-group">
          <h3>This statement is about you</h3>
          <p class="hint">
            Confirming makes it active at full confidence. Contesting marks it disputed and
            queues it for a curator. Redacting withdraws it.
          </p>
          <div class="button-row">
            <button type="button" class="primary" phx-click="subject" phx-value-verdict="confirm">
              Confirm
            </button>
            <button type="button" phx-click="subject" phx-value-verdict="contest">Contest</button>
            <button type="button" class="danger" phx-click="subject" phx-value-verdict="redact">
              Redact
            </button>
          </div>
        </div>
      </.panel>

      <.panel
        title="Provenance"
        description="Every recorded route by which this statement entered the system."
      >
        <.empty :if={@detail.provenance == []} message="No provenance rows are attached." />
        <table :if={@detail.provenance != []} class="grid">
          <thead>
            <tr>
              <th>When</th>
              <th>Source</th>
              <th>Reference</th>
              <th>Extracted by</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @detail.provenance}>
              <td class="nowrap">{timestamp(row.occurred_at)}</td>
              <td><.badge family="kind" value={row.source_type} /></td>
              <td>
                <.id_chip :if={row.message_id} value={row.message_id} />
                <.id_chip :if={row.document_version_id} value={row.document_version_id} />
              </td>
              <td class="muted">{row.extracting_model || "—"}</td>
            </tr>
          </tbody>
        </table>
      </.panel>

      <.panel
        title="Raw observations behind it"
        description="What was actually said. Extraction produced the statement above from these."
      >
        <.empty
          :if={@detail.messages == []}
          message="No raw observation is readable for this statement — it may have come from a document, or from a scope you cannot read."
        />
        <article :for={message <- @detail.messages} class="quote">
          <p class="quote-meta">
            {message.role} · {timestamp(message.occurred_at)} · session <.id_chip value={
              message.session_id
            } />
          </p>
          <p>{message.content}</p>
        </article>
      </.panel>

      <.panel
        :if={@detail.document_versions != []}
        title="Document versions behind it"
        description="Documents are versioned immutably; a changed document appends a version rather than overwriting one."
      >
        <table class="grid">
          <thead>
            <tr>
              <th>Version</th>
              <th>Media type</th>
              <th>Bytes</th>
              <th>Status</th>
              <th>Recorded</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={version <- @detail.document_versions}>
              <td>v{version.version}</td>
              <td>{version.media_type}</td>
              <td>{version.byte_size}</td>
              <td><.badge family="state" value={version.processing_status} /></td>
              <td class="nowrap muted">{timestamp(version.occurred_at)}</td>
            </tr>
          </tbody>
        </table>
      </.panel>

      <.panel
        title="Lifecycle"
        description="Append-only. Every state change writes an event here in the same transaction that made the change."
      >
        <.empty :if={@detail.lifecycle == []} message="No transition has been recorded." />
        <ol :if={@detail.lifecycle != []} class="timeline">
          <li :for={event <- @detail.lifecycle}>
            <span class="timeline-when">{timestamp(event.occurred_at)}</span>
            <span :if={event.from_state} class="muted">{event.from_state} →</span>
            <.badge family="state" value={event.to_state} />
            <span class="muted">{event.reason}</span>
          </li>
        </ol>
      </.panel>

      <.panel
        :if={@detail.gate_decisions != []}
        title="Gate decisions"
        description="Immutable record of each automatic and human gate result. Visible to curators, because the decision rows are curator-scoped."
      >
        <table class="grid">
          <thead>
            <tr>
              <th>When</th>
              <th>Gate</th>
              <th>Decision</th>
              <th>Channel</th>
              <th>Transition</th>
              <th>Decided by</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={decision <- @detail.gate_decisions}>
              <td class="nowrap">{timestamp(decision.decided_at)}</td>
              <td>{decision.gate}</td>
              <td><.badge family="decision" value={decision.decision} /></td>
              <td class="muted">{decision.channel}</td>
              <td class="muted">{decision.from_state} → {decision.to_state}</td>
              <td><.id_chip value={decision.actor_peer_id} /></td>
            </tr>
          </tbody>
        </table>
      </.panel>

      <.panel
        title="Cross-references"
        description="Relations, conflicts, and the supersession chain. A link to a statement you cannot read is omitted entirely rather than shown as a dead id."
      >
        <div :if={@detail.superseded} class="chain">
          <h3>Supersedes</h3>
          <p>
            <.link navigate={~p"/console/knowledge/#{@detail.superseded.id}"}>
              {truncate(@detail.superseded.statement, 140)}
            </.link>
          </p>
        </div>

        <div :if={@detail.successors != []} class="chain">
          <h3>Superseded by</h3>
          <p :for={item <- @detail.successors}>
            <.link navigate={~p"/console/knowledge/#{item.id}"}>
              {truncate(item.statement, 140)}
            </.link>
          </p>
        </div>

        <.empty
          :if={@detail.related == [] and is_nil(@detail.superseded) and @detail.successors == []}
          message="This statement stands on its own — nothing links to it and it supersedes nothing."
        />

        <table :if={@detail.related != []} class="grid">
          <thead>
            <tr>
              <th>Statement</th>
              <th>Scope</th>
              <th>State</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={item <- @detail.related}>
              <td>
                <.link navigate={~p"/console/knowledge/#{item.id}"}>
                  {truncate(item.statement, 160)}
                </.link>
              </td>
              <td class="nowrap">{item.scope_path || "(unreadable scope)"}</td>
              <td><.badge family="state" value={item.state} /></td>
            </tr>
          </tbody>
        </table>
      </.panel>

      <.panel
        :if={@detail.attributions != []}
        title="Attribution"
        description="Who or what this statement has been attributed to, and at what level."
      >
        <table class="grid">
          <thead>
            <tr>
              <th>Target</th>
              <th>Reference</th>
              <th>Level</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @detail.attributions}>
              <td>{row.target_type}</td>
              <td>
                <.id_chip :if={row.target_peer_id} value={row.target_peer_id} />
                <.id_chip :if={row.target_scope_id} value={row.target_scope_id} />
              </td>
              <td><.badge family="level" value={row.level} /></td>
            </tr>
          </tbody>
        </table>
      </.panel>
    </.shell>
    """
  end

  # Re-reads the whole page from the database and recomputes which controls the
  # reader is entitled to. Called on mount and after every attempted action, so
  # what is rendered is always committed state.
  defp load(socket, id) do
    actor = socket.assigns.current_actor
    detail = Loader.knowledge_detail(actor, id)

    socket
    |> assign(:detail, detail)
    |> assign(:actions, actions(actor, detail))
  end

  # Which control groups to render. Curator decisions need an open queue entry
  # to act on, because approve, reject, defer, edit, and merge all operate on a
  # queue row rather than directly on the statement. Promotion needs a strict
  # ancestor to promote into, so a statement already at the root offers none.
  defp actions(_actor, nil), do: %{any?: false}

  defp actions(actor, detail) do
    curate? = Access.can?(actor, :curate) and not is_nil(detail.validation)
    targets = promotion_targets(detail)
    promote? = Access.can?(actor, :promote) and targets != []
    subject? = Access.subject_of?(actor, detail.item)

    %{
      any?: curate? or promote? or subject?,
      curate: curate?,
      promote: promote?,
      subject: subject?,
      promotion_targets: targets
    }
  end

  # Promotion may only widen exposure along the containment tree, so the offered
  # targets are the strict ancestors of the statement's current scope — and only
  # those this reader can see. Sideways and downward moves are rejected by the
  # operation layer; not offering them here keeps the reader from discovering
  # that by trying.
  defp promotion_targets(detail) do
    case detail.item.scope_path do
      nil ->
        []

      path ->
        detail.scopes
        |> Enum.filter(&(&1.path != path and ancestor?(&1.path, path)))
        |> Enum.sort_by(&String.length(&1.path), :desc)
    end
  end

  defp ancestor?("/", _path), do: true
  defp ancestor?(candidate, path), do: String.starts_with?(path, candidate <> "/")

  # Runs one operation-layer call and turns its outcome into a flash.
  #
  # The rescued cases are all ordinary: a hand-typed merge target that names
  # nothing, a blank replacement statement, or an authority the operation layer
  # declined. Letting those crash the socket would drop the reader back to a
  # remounted page with no explanation of what went wrong. The refusal message
  # is deliberately the same for all of them, so a reader cannot use the error
  # text to learn which ids exist.
  defp guard(socket, success_message, fun) do
    actor = socket.assigns.current_actor
    id = socket.assigns.detail.item.id

    socket =
      try do
        fun.(actor)
        put_flash(socket, :info, success_message)
      rescue
        error in [Ash.Error.Forbidden, Ash.Error.Query.NotFound, Ash.Error.Invalid] ->
          _ = error
          put_flash(socket, :error, "That action was refused. Nothing was changed.")

        error in [ArgumentError, KeyError] ->
          _ = error
          put_flash(socket, :error, "That action needs a valid value. Nothing was changed.")
      end

    {:noreply, load(socket, id)}
  end
end
