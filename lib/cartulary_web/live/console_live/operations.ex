# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.ConsoleLive.Operations do
  @moduledoc """
  The operator view at `/console/operations`: readiness, recorded usage, the
  gate matrix, and the retrieval tunings currently in force.

  ## Account administrators only

  The mount hook admits any person to the console; this page turns most of them
  away again. Every resource behind it — the usage ledger, gate rules,
  pipeline runs — is guarded by a plain role check with no filter, so a member
  asking for them is refused outright rather than shown an empty list. The
  redirect here is therefore not merely cosmetic: without it the page would
  crash instead of declining.

  ## Everything shown is content-safe

  Readiness may report component status, queue depths, model identities,
  versions, and error classes. It must never report credentials or stored
  content, and nothing on this page renders either. Gate rules and retrieval
  profiles are configuration: they hold thresholds, modes, and strategy
  weights, never statement text, examples, or secrets.

  The cost figure is computed from operator-supplied rates over this
  installation's own ledger. It is a self-host visibility aid, not a bill, and
  there is no hidden billing state behind it.

  ## This page is read-only

  Gate rules and retrieval tunings change behaviour for everyone in a scope, so
  editing them is a deliberate act that belongs behind a reviewed path rather
  than a console form. What is shown here is what is currently in force, so an
  operator can see it without reading the database.
  """

  use CartularyWeb, :live_view

  import CartularyWeb.ConsoleComponents

  alias Cartulary.Operations.Health
  alias Cartulary.Operations.Metering
  alias CartularyWeb.Console.Access
  alias CartularyWeb.Console.Loader

  @doc """
  Loads the operational view, or redirects a reader who is not an account
  administrator back to the overview.

  The check happens before any query runs. Reversing that order would issue a
  read that the resource refuses, turning a polite redirect into a crash.
  """
  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_actor

    if Access.can?(actor, :administer) do
      {:ok,
       socket
       |> assign(:health, Health.readiness())
       |> assign(:usage, Metering.summary(actor))
       |> assign(:operations, Loader.operations(actor))}
    else
      {:ok,
       socket
       |> put_flash(:error, "The operations view is limited to account administrators.")
       |> push_navigate(to: ~p"/console")}
    end
  end

  @doc """
  Renders readiness, usage, gate rules, and retrieval profiles.

  Guards on the assigns rather than the actor, because the unauthorized mount
  redirects without assigning anything and LiveView still renders once before
  the navigation takes effect.
  """
  @impl true
  def render(%{health: _health} = assigns) do
    ~H"""
    <.shell actor={@current_actor} active={:operations} title="Operations" flash={@flash}>
      <:subtitle>
        Component status, recorded usage, and the rules currently governing gates and
        retrieval. Read-only: changing behaviour for a whole scope is a reviewed act.
      </:subtitle>

      <.panel
        title="Readiness"
        description="Component status, queue depth, and configured model identities. Never credentials, never stored content."
      >
        <div class="tiles">
          <.tile
            label="Overall"
            value={@health.status}
            tone={if @health.status == "ready", do: "accent", else: "danger"}
            note={@health.version}
          />
          <.tile
            :for={{component, check} <- Enum.sort_by(@health.checks, &elem(&1, 0))}
            label={to_string(component)}
            value={check.status}
            tone={if check.status == "ok", do: "neutral", else: "danger"}
            note={check[:error_class]}
          />
        </div>

        <pre class="code">{inspect(@health.checks, pretty: true, limit: :infinity)}</pre>
      </.panel>

      <.panel
        title="Recorded usage"
        description="Counted from this installation's own ledger. The cost estimate applies operator-supplied rates; there is no hidden billing state."
      >
        <div class="tiles">
          <.tile label="Ledger events" value={@usage.event_count} />
          <.tile label="API requests" value={@usage.api_requests} />
          <.tile label="Ingests" value={@usage.ingests} />
          <.tile label="Logical storage" value={"#{@usage.logical_storage_bytes} B"} />
          <.tile
            label="Estimated model cost"
            value={"#{@usage.estimated_model_cost} #{@usage.currency}"}
          />
        </div>

        <table class="grid">
          <thead>
            <tr>
              <th>Model role</th>
              <th>Input tokens</th>
              <th>Output tokens</th>
              <th>Embedding tokens</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={{role, tokens} <- Enum.sort_by(@usage.tokens_by_role, &elem(&1, 0))}>
              <td>{role || "—"}</td>
              <td class="nowrap">{tokens.input}</td>
              <td class="nowrap">{tokens.output}</td>
              <td class="nowrap">{tokens.embedding}</td>
            </tr>
          </tbody>
        </table>
      </.panel>

      <.panel
        title="Gate matrix"
        description="Which combinations of target level, sensitivity, and confidence are decided automatically and which wait for a person. The most specific matching rule with the highest priority wins."
      >
        <.empty
          :if={@operations.gate_rules == []}
          message="No stored gate rule. The compiled-in conservative matrix is in force."
        />

        <table :if={@operations.gate_rules != []} class="grid">
          <thead>
            <tr>
              <th>Scope</th>
              <th>Target level</th>
              <th>Sensitivity</th>
              <th>Min confidence</th>
              <th>Gate A</th>
              <th>Gate B</th>
              <th>Corroboration</th>
              <th>Consent</th>
              <th>Priority</th>
              <th>Active</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={rule <- @operations.gate_rules}>
              <td>{rule.scope_id && scope_path(@operations.scope_paths, rule.scope_id) || "account-wide"}</td>
              <td><.badge family="level" value={rule.target_level} /></td>
              <td><.badge family="sensitivity" value={rule.sensitivity} /></td>
              <td class="nowrap">{rule.minimum_confidence}</td>
              <td><.badge family="decision" value={rule.gate_a_mode} /></td>
              <td><.badge family="decision" value={rule.gate_b_mode} /></td>
              <td class="nowrap">{rule.minimum_corroboration}</td>
              <td>{if rule.requires_consent, do: "required", else: "—"}</td>
              <td class="nowrap">{rule.priority}</td>
              <td>{if rule.active, do: "yes", else: "no"}</td>
            </tr>
          </tbody>
        </table>
      </.panel>

      <.panel
        title="Retrieval tunings"
        description="Stored overrides of the built-in profiles. They inherit down the scope tree, nearest scope winning, and the highest active version applies."
      >
        <.empty
          :if={@operations.retrieval_profiles == []}
          message="No stored override. The compiled-in fast, balanced, and thorough profiles are in force."
        />

        <table :if={@operations.retrieval_profiles != []} class="grid">
          <thead>
            <tr>
              <th>Profile</th>
              <th>Scope</th>
              <th>Version</th>
              <th>Deadline</th>
              <th>Active</th>
              <th>Configuration</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={profile <- @operations.retrieval_profiles}>
              <td>{profile.name}</td>
              <td>
                {profile.scope_id && scope_path(@operations.scope_paths, profile.scope_id) ||
                  "account-wide"}
              </td>
              <td class="nowrap">{profile.version}</td>
              <td class="nowrap">{profile.deadline_ms} ms</td>
              <td>{if profile.active, do: "yes", else: "no"}</td>
              <td><pre class="code inline">{Jason.encode!(profile.strategy_config)}</pre></td>
            </tr>
          </tbody>
        </table>
      </.panel>
    </.shell>
    """
  end

  # The unauthorized mount assigns nothing and navigates away, but LiveView
  # still renders once before the navigation is applied. This clause is that
  # single frame.
  def render(assigns) do
    ~H"""
    <div class="app">
      <main class="content">
        <p class="lede">Redirecting…</p>
      </main>
    </div>
    """
  end
end
