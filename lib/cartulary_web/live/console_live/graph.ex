# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.ConsoleLive.Graph do
  @moduledoc """
  Read-only `/console/graph` view of authorized scopes, statements, and their
  relations.

  Entity caches, names, aliases, surface forms, and ids must never appear.
  Geometry is deterministic server-side SVG: no inline scripts, randomness, or
  wall clock. The page reports when statement limits truncate the graph.
  """

  use CartularyWeb, :live_view

  import CartularyWeb.ConsoleComponents

  alias CartularyWeb.Console.Graph
  alias CartularyWeb.Console.Loader

  @doc """
  Mounts with no selected node; `handle_params/3` loads the URL-filtered graph.
  """
  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :selected, nil)}
  end

  @doc """
  Loads and lays out the selected scope or all authorized scopes.
  """
  @impl true
  def handle_params(params, _uri, socket) do
    scope = blank_to_nil(params["scope"])
    data = Loader.graph(socket.assigns.current_actor, scope: scope)

    {:noreply,
     socket
     |> assign(:scope, scope)
     |> assign(:data, data)
     # Phoenix reserves the `:layout` assign.
     |> assign(:diagram, Graph.build(data))
     |> assign(:selected, nil)}
  end

  @doc """
  Handles scope filters and selects only nodes in the authorized loaded set.

  Unknown client-supplied ids select nothing; never query them directly.
  """
  @impl true
  def handle_event("filter", params, socket) do
    query = if params["scope"] in [nil, ""], do: %{}, else: %{"scope" => params["scope"]}
    {:noreply, push_patch(socket, to: ~p"/console/graph?#{query}")}
  end

  def handle_event("select", %{"id" => id, "kind" => "scope"}, socket) do
    scope = Enum.find(socket.assigns.data.scopes, &(&1.id == id))
    {:noreply, assign(socket, :selected, scope && {:scope, scope})}
  end

  def handle_event("select", %{"id" => id, "kind" => "knowledge"}, socket) do
    item = Enum.find(socket.assigns.data.knowledge, &(&1.id == id))
    {:noreply, assign(socket, :selected, item && {:knowledge, item})}
  end

  def handle_event("deselect", _params, socket), do: {:noreply, assign(socket, :selected, nil)}

  @doc """
  Renders the filter, the SVG, the legend, and the selection panel.
  """
  @impl true
  def render(assigns) do
    ~H"""
    <.shell actor={@current_actor} active={:graph} title="Graph" flash={@flash}>
      <:subtitle>
        Distance from the centre is depth in the containment tree. Lines that cross the rings
        are cross-references rather than containment.
      </:subtitle>

      <.panel
        title="View"
        description="Narrowing to a scope draws that scope and everything contained in it."
      >
        <form phx-change="filter" class="filters">
          <label class="grow">
            Scope
            <select name="scope">
              <option value="">Everything you can read</option>
              <option :for={scope <- @data.all_scopes} value={scope.path} selected={@scope == scope.path}>
                {scope.path}
              </option>
            </select>
          </label>
        </form>

        <p :if={@data.truncated?} class="hint">
          More statements match than are drawn. The graph shows the most confident ones; use
          the <.link navigate={~p"/console/knowledge"}>explorer</.link> for the complete list.
        </p>
      </.panel>

      <div class="graph-layout">
        <div class="graph-frame">
          <.empty
            :if={@diagram.nodes == []}
            message="Nothing to draw: no scope is reachable with your current grants."
          />

          <svg
            :if={@diagram.nodes != []}
            class="graph"
            viewBox={"0 0 #{@diagram.width} #{@diagram.height}"}
            role="img"
            aria-label="Scope and statement graph"
          >
            <%!--
              Edges are drawn before nodes so that nodes sit on top of the lines
              rather than being crossed by them. SVG has no z-index; document
              order is the stacking order.
            --%>
            <line
              :for={edge <- @diagram.edges}
              class={"edge edge-#{edge.kind}"}
              x1={edge.x1}
              y1={edge.y1}
              x2={edge.x2}
              y2={edge.y2}
            />

            <g
              :for={node <- @diagram.nodes}
              class={["node", "node-#{node.kind}", node.class]}
              phx-click="select"
              phx-value-id={node.id}
              phx-value-kind={node.kind}
            >
              <circle cx={node.x} cy={node.y} r={node.r} />
              <title>{node.title}</title>
              <text :if={node.label} x={node.x} y={node.y + node.r + 14} text-anchor="middle">
                {node.label}
              </text>
            </g>
          </svg>
        </div>

        <aside class="graph-panel">
          <div :if={is_nil(@selected)} class="graph-hint">
            <h3>Legend</h3>
            <ul class="legend">
              <li><span class="swatch node-scope"></span> Scope — larger at the root</li>
              <li>
                <span class="swatch node-knowledge"></span>
                Statement — size is confidence, colour is lifecycle state
              </li>
              <li><span class="swatch edge-containment"></span> Containment</li>
              <li><span class="swatch edge-membership"></span> Statement lives in scope</li>
              <li><span class="swatch edge-scope_relation"></span> Scope relation</li>
              <li><span class="swatch edge-knowledge_relation"></span> Statement relation</li>
            </ul>
            <p class="hint">Select a node to see what it is.</p>
          </div>

          <div :if={match?({:scope, _scope}, @selected)} class="graph-selection">
            <h3>Scope</h3>
            <p class="statement">{elem(@selected, 1).path}</p>
            <dl class="pairs">
              <dt>Name</dt>
              <dd>{elem(@selected, 1).name}</dd>
              <dt>State</dt>
              <dd><.badge family="state" value={elem(@selected, 1).state} /></dd>
            </dl>
            <p>
              <.link navigate={~p"/console/knowledge?#{[scope: elem(@selected, 1).path]}"}>
                Browse its statements
              </.link>
            </p>
            <button type="button" class="ghost" phx-click="deselect">Clear selection</button>
          </div>

          <div :if={match?({:knowledge, _item}, @selected)} class="graph-selection">
            <h3>Statement</h3>
            <p class="statement">{elem(@selected, 1).statement}</p>
            <div class="badge-row">
              <.badge family="state" value={elem(@selected, 1).state} />
              <.badge family="kind" value={elem(@selected, 1).kind} />
              <.badge family="sensitivity" value={elem(@selected, 1).sensitivity} />
            </div>
            <p class="muted">{elem(@selected, 1).scope_path || "(unreadable scope)"}</p>
            <p>
              <.link navigate={~p"/console/knowledge/#{elem(@selected, 1).id}"}>
                Open the full record
              </.link>
            </p>
            <button type="button" class="ghost" phx-click="deselect">Clear selection</button>
          </div>
        </aside>
      </div>
    </.shell>
    """
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
