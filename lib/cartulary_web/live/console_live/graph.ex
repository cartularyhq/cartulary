# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.ConsoleLive.Graph do
  @moduledoc """
  The graph view at `/console/graph`: the shape of the memory, drawn as scopes,
  the statements inside them, and the links between both.

  ## What the picture means

  Distance from the centre is depth in the containment tree, so the root sits
  in the middle and a nested scope sits further out. Each scope's statements
  orbit it, so a dense scope is visibly dense. Two kinds of line cross the
  rings rather than following them: a scope relation, which links scopes that
  are not in a parent-child line, and a knowledge relation, which links two
  statements. Those crossings are the interesting part — containment is
  predictable, cross-references are not.

  ## Why there are no entity nodes

  A tempting third node type would be the resolved entities behind the
  statements. They are deliberately absent. Entity rows are a private recall
  cache whose rows span every scope that ever mentioned a name, so drawing them
  would carry names across scope boundaries that the scope tree exists to keep
  apart. Their read action is pipeline-only, so an attempt to add them fails
  loudly; do not work around that by elevating the actor.

  ## Why the drawing is server-side SVG

  The browser pages are served under a Content-Security-Policy that forbids
  inline script and permits only same-origin modules, and the project has no
  bundler. The geometry is therefore computed in Elixir and rendered as plain
  SVG elements, which LiveView can patch and bind `phx-click` to. Selecting a
  node is a server round-trip — which is also what lets the detail panel show
  authorized information without shipping the whole corpus to the browser.

  ## Truncation is stated, never silent

  A graph with hundreds of statement nodes is unreadable, so the number drawn
  is capped. When the cap drops rows the page says so. A partial picture
  presented as a complete one is worse than no picture.

  This page performs no writes.
  """

  use CartularyWeb, :live_view

  import CartularyWeb.ConsoleComponents

  alias CartularyWeb.Console.Graph
  alias CartularyWeb.Console.Loader

  @doc """
  Mounts with nothing selected. The data itself is loaded in
  `handle_params/3`, so the scope filter can live in the URL and a particular
  view of the graph can be linked to.
  """
  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :selected, nil)}
  end

  @doc """
  Loads the graph for the scope named in the URL, or for everything the reader
  can see when none is named, and lays it out.
  """
  @impl true
  def handle_params(params, _uri, socket) do
    scope = blank_to_nil(params["scope"])
    data = Loader.graph(socket.assigns.current_actor, scope: scope)

    {:noreply,
     socket
     |> assign(:scope, scope)
     |> assign(:data, data)
     # Named `:diagram` rather than the more obvious `:layout`, which Phoenix
     # reserves for the rendering layout. Assigning to it makes the controller
     # try to render this map as a template.
     |> assign(:diagram, Graph.build(data))
     |> assign(:selected, nil)}
  end

  @doc """
  Handles the scope filter and node selection.

  Selecting a node looks the node up in the data already loaded rather than
  querying again. That is safe because the loaded set was filtered by the
  reader's authority when it was fetched — but it is also why nothing here may
  take an id from the client and query with it: an id that is not in the
  current view resolves to `nil` and selects nothing, which is the correct
  answer for a forged event.
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
