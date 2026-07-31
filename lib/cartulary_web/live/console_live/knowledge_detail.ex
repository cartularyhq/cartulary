# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.ConsoleLive.KnowledgeDetail do
  @moduledoc """
  `/console/knowledge/:id` transparency and governance controls for one visible
  statement, including provenance, identities, lifecycle, relations, and
  supersession.

  Curators decide queued items and request ancestor promotion; subjects confirm,
  contest, or redact only their own statements. Editing creates a governed
  replacement and preserves the original. Controls only aid presentation: every
  event delegates to governance operations, which reauthorize and own locks,
  transactions, decisions, lifecycle events, and audit records.

  Rendered statement and source text is browser-only. Never copy it into logs,
  telemetry, audit metadata, or job args.
  """

  use CartularyWeb, :live_view

  import CartularyWeb.ConsoleComponents

  alias Cartulary.Governance.Engine
  alias CartularyWeb.Console.Access
  alias CartularyWeb.Console.Loader

  @doc """
  Loads one statement, or renders the not-found state.

  Missing and unauthorized ids are indistinguishable to prevent existence
  probing.
  """
  @impl true
  def mount(%{"id" => id}, _session, socket) do
    {:ok, load(socket, id)}
  end

  @doc """
  Delegates curator decisions, promotion requests, and subject verdicts.

  Refusals become generic flashes, and every attempt reloads committed state.
  """
  @impl true
  # Reject forged events on the not-found state before accessing the statement.
  def handle_event(_event, _params, %{assigns: %{detail: nil}} = socket) do
    {:noreply, put_flash(socket, :error, "That action was refused. Nothing was changed.")}
  end

  def handle_event("decide", %{"action" => action} = params, socket) do
    # Blank optional fields mean absent, not an empty replacement value.
    opts =
      params
      |> Map.take(["statement", "merge_into_id", "defer_hours", "sensitivity"])
      |> Map.reject(fn {_key, value} -> value in [nil, ""] end)

    # Decisions require an open queue row; forged events fail closed.
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

  # Reload committed state and recompute visible controls after each attempt.
  defp load(socket, id) do
    actor = socket.assigns.current_actor
    detail = Loader.knowledge_detail(actor, id)

    socket
    |> assign(:detail, detail)
    |> assign(:actions, actions(actor, detail))
  end

  # Decisions need a queue row; promotion needs a strict ancestor.
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

  # Offer only authorized strict ancestors; operations reject other moves.
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

  # Keep refusal messages generic so operation errors cannot reveal ids.
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
