# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.ConsoleLive.Me do
  @moduledoc """
  Subject self-governance at `/console/me`: everything the system says about
  the signed-in person, and what they can do about it.

  ## Why this page ignores the scope tree

  Every other console page shows what the reader's role grants reach. This one
  additionally shows every statement whose subject is the reader, wherever it
  lives — including scopes they hold no role on. A person may read what is
  recorded about them even when they cannot read the scope it sits in, and that
  exemption is what makes contesting, redacting, and erasure meaningful rather
  than theoretical. The exemption lives in the governance operation layer, not
  here.

  ## Three kinds of authority, all personal

  - **Verdicts.** Confirm makes a statement active at full confidence, because
    first-hand confirmation by its subject is the strongest evidence available.
    Contest marks it disputed and queues it for a curator within 24 hours.
    Redact withdraws it. None of these is a curator power, and a curator cannot
    exercise them on someone's behalf.
  - **Consent.** Personal knowledge being promoted to a wider scope waits for
    the subject's own target-specific consent. A curator approval is never a
    substitute for it. A grant is accepted only over a channel whose speaker
    was actually authenticated — a password browser session is one — while a
    refusal is recorded regardless, because it must never be harder to refuse
    exposure than to allow it.
  - **Erasure.** Proportionate erasure removes the subject's content and
    scrubs shared provenance. Strict erasure additionally removes knowledge
    that was only ever sourced through the subject. Both retain content-safe
    audit evidence: what was removed leaves a trace that records no removed
    content.

  ## Erasure is confirmed, not one-clicked

  Erasure runs immediately and cannot be undone. The page therefore requires
  the reader to choose a mode and type the word `erase` before the control does
  anything. That is a deliberate friction, not an oversight — do not replace it
  with a single button.

  This module writes nothing directly. Every action forwards to the governance
  operation layer, which owns the transaction, the lifecycle event, and the
  hash-chained audit entry.
  """

  use CartularyWeb, :live_view

  import CartularyWeb.ConsoleComponents

  alias Cartulary.Governance.Engine
  alias Cartulary.Governance.Erasure
  alias CartularyWeb.Console.Access
  alias CartularyWeb.Console.Loader

  @doc """
  Loads the statements about this person, their consent requests, and their
  erasure history.

  An actor with no peer id cannot reach this page in a meaningful sense — there
  is no "me" to show — so it renders an explanation instead. The console mount
  hook admits only password identities, which always carry a peer, so this is a
  defensive branch for a case that should not arise rather than a routine one.
  """
  @impl true
  def mount(_params, _session, socket) do
    {:ok, load(socket)}
  end

  @doc """
  Applies one subject verdict, one consent answer, or one erasure request.

  Refusals from the operation layer become a flash rather than crashing the
  socket. The message is deliberately generic: a reader must not be able to use
  the error text to learn which statement ids or consent rows exist.

  Consent grants are submitted as verified because a password browser session
  authenticated the person answering. Do not pass `true` from a channel where
  that is not true — an unverified grant is refused by the operation layer, and
  lying to it here would defeat the check.
  """
  @impl true
  def handle_event("verdict", %{"id" => id, "verdict" => verdict}, socket) do
    guard(socket, "Recorded.", fn actor -> Engine.contest(actor, id, verdict) end)
  end

  def handle_event("consent", params, socket) do
    %{"id" => knowledge_id, "scope" => target_scope_id, "verdict" => verdict} = params

    guard(socket, "Consent answer recorded.", fn actor ->
      case Engine.subject_consent(actor, knowledge_id, target_scope_id, verdict, true, "console") do
        {:error, reason} -> raise ArgumentError, "consent refused: #{inspect(reason)}"
        other -> other
      end
    end)
  end

  def handle_event("erase", %{"mode" => mode, "confirm" => confirm}, socket) do
    actor = socket.assigns.current_actor

    if String.downcase(String.trim(confirm)) == "erase" do
      guard(socket, "Erasure completed.", fn current ->
        Erasure.request(current, actor.peer_id, mode)
      end)
    else
      {:noreply, put_flash(socket, :error, "Type erase to confirm. Nothing was removed.")}
    end
  end

  @doc """
  Renders the personal view: statements about the reader, pending consent, and
  the erasure controls.
  """
  @impl true
  def render(assigns) do
    ~H"""
    <.shell actor={@current_actor} active={:me} title="About me" flash={@flash}>
      <:subtitle>
        Every statement whose subject is you, wherever it lives — including scopes you hold
        no role on. Reading what is recorded about you does not require a grant.
      </:subtitle>

      <.panel
        :if={not Access.can?(@current_actor, :self_govern)}
        title="No personal view"
        description="This session is not tied to a person, so there is nothing to show here."
      >
        <p>Subject gestures are available only to a signed-in person.</p>
      </.panel>

      <.panel
        :if={Access.can?(@current_actor, :self_govern)}
        title={"#{length(@about_me)} statement(s) about you"}
        description="Confirm makes a statement active at full confidence. Contest marks it disputed and queues it for a curator. Redact withdraws it."
      >
        <.empty :if={@about_me == []} message="Nothing has been recorded about you." />

        <article :for={item <- @about_me} class="record">
          <p class="statement">{item.statement}</p>
          <div class="badge-row">
            <.badge family="state" value={item.state} />
            <.badge family="kind" value={item.kind} />
            <.badge family="sensitivity" value={item.sensitivity} />
            <span class="badge">confidence {Float.round(item.confidence * 1.0, 2)}</span>
            <span class="muted">{scope_path(@self.scope_paths, item.scope_id)}</span>
          </div>
          <div class="button-row">
            <button
              type="button"
              class="primary"
              phx-click="verdict"
              phx-value-id={item.id}
              phx-value-verdict="confirm"
              title="Confirm this is true. Makes it active at full confidence — the strongest evidence, since it comes from you."
            >
              Confirm — this is true
            </button>
            <button
              type="button"
              phx-click="verdict"
              phx-value-id={item.id}
              phx-value-verdict="contest"
              title="Dispute this without removing it. Marks it disputed and sends it to a curator for review within 24 hours."
            >
              Contest — dispute this
            </button>
            <button
              type="button"
              class="danger"
              phx-click="verdict"
              phx-value-id={item.id}
              phx-value-verdict="redact"
              title="Withdraw this statement outright. Different from Erasure below: this retracts one statement, Erasure removes underlying data."
            >
              Redact — withdraw this
            </button>
            <.link navigate={~p"/console/knowledge/#{item.id}"} class="ghost-link">
              Full record
            </.link>
          </div>
        </article>
      </.panel>

      <.panel
        :if={Access.can?(@current_actor, :self_govern)}
        title="Consent requests"
        description="Personal knowledge being promoted to a wider scope waits for your own consent. A curator approval is never a substitute for it."
      >
        <.empty :if={@self.consents == []} message="No consent request is waiting for you." />

        <table :if={@self.consents != []} class="grid">
          <thead>
            <tr>
              <th>Statement</th>
              <th>Target scope</th>
              <th>Status</th>
              <th>Decided</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={consent <- @self.consents}>
              <td>
                <.id_chip
                  value={consent.knowledge_id}
                  navigate={~p"/console/knowledge/#{consent.knowledge_id}"}
                />
              </td>
              <td>{scope_path(@self.scope_paths, consent.target_scope_id)}</td>
              <td><.badge family="decision" value={consent.status} /></td>
              <td class="nowrap muted">{timestamp(consent.decided_at)}</td>
              <td>
                <div :if={consent.status == "pending"} class="button-row">
                  <button
                    type="button"
                    class="primary"
                    phx-click="consent"
                    phx-value-id={consent.knowledge_id}
                    phx-value-scope={consent.target_scope_id}
                    phx-value-verdict="grant"
                  >
                    Grant
                  </button>
                  <button
                    type="button"
                    phx-click="consent"
                    phx-value-id={consent.knowledge_id}
                    phx-value-scope={consent.target_scope_id}
                    phx-value-verdict="deny"
                  >
                    Deny
                  </button>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </.panel>

      <.panel
        :if={Access.can?(@current_actor, :self_govern)}
        title="Erasure"
        description="Runs immediately and cannot be undone. Content-safe audit evidence is retained: the trace records that something was removed, never what."
      >
        <p>
          <strong>Proportionate</strong> removes your content and scrubs shared provenance.
          <strong>Strict</strong> additionally removes knowledge that was only ever sourced
          through you. Neither retracts knowledge that still has independent provenance.
        </p>

        <form phx-submit="erase" class="filters">
          <label>
            Mode
            <select name="mode">
              <option value="proportionate">Proportionate</option>
              <option value="strict">Strict</option>
            </select>
          </label>
          <label class="grow">
            Type <code>erase</code> to confirm
            <input name="confirm" autocomplete="off" placeholder="erase" />
          </label>
          <button class="danger">Erase my data</button>
        </form>

        <.empty :if={@self.erasures == []} message="You have made no erasure request." />
        <table :if={@self.erasures != []} class="grid">
          <thead>
            <tr>
              <th>Requested</th>
              <th>Mode</th>
              <th>State</th>
              <th>Completed</th>
              <th>Affected</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={request <- @self.erasures}>
              <td class="nowrap">{timestamp(request.requested_at)}</td>
              <td><.badge family="kind" value={request.mode} /></td>
              <td><.badge family="state" value={request.state} /></td>
              <td class="nowrap muted">{timestamp(request.completed_at)}</td>
              <td class="muted">{format_counts(request.affected_counts)}</td>
            </tr>
          </tbody>
        </table>
      </.panel>
    </.shell>
    """
  end

  # Re-reads everything after every action, so the page is committed state
  # rather than an optimistic guess. An erasure in particular changes rows this
  # page is listing, and patching assigns in memory would leave removed
  # statements on screen.
  defp load(socket) do
    actor = socket.assigns.current_actor

    if Access.can?(actor, :self_govern) do
      socket
      |> assign(:about_me, Engine.self_view(actor))
      |> assign(:self, Loader.self_governance(actor))
    else
      socket
      |> assign(:about_me, [])
      |> assign(:self, %{consents: [], erasures: [], scope_paths: %{}})
    end
  end

  # See the note on the same helper in the statement detail page: refusals and
  # bad input are ordinary here, and the message is identical for both so the
  # error text cannot be used to probe for ids.
  defp guard(socket, success_message, fun) do
    socket =
      try do
        fun.(socket.assigns.current_actor)
        put_flash(socket, :info, success_message)
      rescue
        error in [Ash.Error.Forbidden, Ash.Error.Query.NotFound, Ash.Error.Invalid] ->
          _ = error
          put_flash(socket, :error, "That action was refused. Nothing was changed.")

        error in [ArgumentError, KeyError] ->
          _ = error
          put_flash(socket, :error, "That action could not be completed. Nothing was changed.")
      end

    {:noreply, load(socket)}
  end

  # Affected counts are a free-form map written by the erasure run. Rendering
  # them generically means a count added later shows up without a code change.
  defp format_counts(counts) when map_size(counts) == 0, do: "—"

  defp format_counts(counts) do
    counts
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join(", ", fn {key, value} -> "#{key}: #{value}" end)
  end
end
