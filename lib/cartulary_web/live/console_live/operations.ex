# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.ConsoleLive.Operations do
  @moduledoc """
  Read-only, account-administrator view of readiness, usage, entity-resolution
  quality signals, gate rules, and retrieval profiles at `/console/operations`.

  Check the role before querying resources that refuse unauthorized reads.
  Render only content-safe status, counts, model identities, versions, error
  classes, thresholds, and weights—never credentials or stored content. Cost
  estimates use operator-provided rates, not hidden billing state.
  """

  use CartularyWeb, :live_view

  import CartularyWeb.ConsoleComponents

  alias Cartulary.Operations.Health
  alias Cartulary.Operations.Metering
  alias CartularyWeb.Console.Access
  alias CartularyWeb.Console.Loader

  @doc """
  Loads operational data for account administrators; others are redirected.

  Authorization must run before protected resource reads.
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
  Renders operational data when loaded, or a redirect frame otherwise.
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
        title="Software update"
        description="Release availability is signature-verified. Applying an update remains a local operator action."
      >
        <div class="tiles">
          <.tile label="Check" value={@health.update.status} />
          <.tile label="Current" value={@health.update.current_version} />
          <.tile label="Available" value={@health.update.available_version || "—"} />
          <.tile label="Automatic" value={if @health.update.automatic_eligible, do: "eligible", else: "off"} />
        </div>
        <p :if={@health.update.command} class="hint">{@health.update.command}</p>
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
        title="Entity resolution quality"
        description="Content-free cache signals. A high singleton rate can indicate fragmented referents; a high mentions-per-entity tail can indicate distinct referents were folded together."
      >
        <div class="tiles">
          <.tile label="Resolved entities" value={@operations.entity_resolution.entity_count} />
          <.tile label="Entity mentions" value={@operations.entity_resolution.mention_count} />
          <.tile
            label="Singleton entity rate"
            value={percent(@operations.entity_resolution.singleton_entity_rate)}
            note="one mention only"
          />
          <.tile
            label="Mentions per entity p50"
            value={@operations.entity_resolution.mentions_per_entity_p50}
          />
          <.tile
            label="Mentions per entity p95"
            value={@operations.entity_resolution.mentions_per_entity_p95}
          />
        </div>

        <table class="grid">
          <thead>
            <tr>
              <th>Observed aliases per entity</th>
              <th>Entities</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={bucket <- @operations.entity_resolution.aliases_per_entity}>
              <td>{bucket.range}</td>
              <td>{bucket.entity_count}</td>
            </tr>
          </tbody>
        </table>
        <p class="hint">
          These aggregates contain no entity identifiers, canonical names, aliases, or surface
          forms. Compare them over time or after an extractor or resolver change; they are
          diagnostic proxies, not correctness thresholds.
        </p>
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

  # LiveView renders once before applying the unauthorized redirect.
  def render(assigns) do
    ~H"""
    <div class="app">
      <main class="content">
        <p class="lede">Redirecting…</p>
      </main>
    </div>
    """
  end

  defp percent(rate), do: "#{Float.round(rate * 100.0, 1)}%"
end
