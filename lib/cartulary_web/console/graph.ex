# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.Console.Graph do
  @moduledoc """
  Turns the console's graph data into positioned nodes and edges for inline SVG.

  ## Why the layout is computed on the server

  The browser pages are served under a Content-Security-Policy that permits
  scripts only from this origin and forbids inline script, and the project has
  no bundler — the whole client build is one small ES module that starts the
  LiveView socket. Pulling in a graph-drawing library would mean adding both a
  build step and a script exception. Instead the geometry is computed here, in
  Elixir, and the page renders plain SVG elements that LiveView can patch and
  attach `phx-click` to. Selecting a node is a server round-trip, which is also
  what lets the side panel show authorized detail without shipping the whole
  corpus to the browser.

  ## Why the layout is radial rather than force-directed

  A force simulation needs either randomness or many iterations over every pair
  of nodes; the first makes the picture jump on every re-render, and the second
  makes a page load slow on a large Account. This layout is a deterministic
  function of its input: the same scopes and statements always produce the same
  picture, so a reader can return to the graph and find things where they left
  them, and a test can assert on coordinates.

  The shape mirrors what the data means. Scopes sit on concentric rings by
  their depth in the containment tree, so distance from the centre *is* depth.
  Each scope's statements fan out in small orbits around it, so a dense scope
  is visibly dense. Lateral scope relations and statement-to-statement
  relations are drawn as chords across the rings, which is what makes a
  cross-reference stand out from mere containment.

  ## Content safety

  Nodes carry a label and a tooltip built from data the caller already had
  authorization to read. This module performs no queries of its own and must
  never gain any: it cannot re-check authorization, so anything it renders had
  to be filtered before it arrived. In particular there are no entity nodes,
  because entity rows are a private recall cache that spans scope boundaries.
  """

  # The SVG coordinate space. Nothing renders outside it, so every computed
  # position is clamped into it; a node pushed past the edge by a deep tree is
  # pinned to the border rather than silently disappearing.
  @width 1000
  @height 720

  # Radius of the innermost ring, and the gap between successive depth rings,
  # both in SVG units. Together they decide how many depth levels fit before
  # the outer ring reaches the frame edge: (min(width, height) / 2 - margin -
  # base) / step, which is five levels below the root at these values.
  @ring_base 96
  @ring_step 104

  # Orbit geometry for the statements around a scope. Up to @orbit_capacity
  # statements share one orbit; beyond that a further orbit is added
  # @orbit_step further out, so a scope with many statements grows outward
  # instead of overlapping itself.
  @orbit_base 44
  @orbit_step 20
  @orbit_capacity 10

  @doc """
  Positions every scope and statement and returns the drawable model.

  `data` is the map produced by `CartularyWeb.Console.Loader.graph/2`.

  Returns `%{width:, height:, nodes:, edges:}`. Each node is
  `%{id:, kind:, x:, y:, r:, label:, title:, class:, scope_id:}` where `kind` is
  `:scope` or `:knowledge` and `class` is the CSS class naming its lifecycle
  state or scope depth. Each edge is `%{kind:, x1:, y1:, x2:, y2:}` with `kind`
  one of `:containment`, `:membership`, `:scope_relation`, or
  `:knowledge_relation`.

  Edges whose endpoints are not both present are dropped. The loader already
  filters them, and this second drop exists so a future caller cannot produce a
  line to nowhere — which would disclose that an unseen node exists.
  """
  def build(data) do
    scope_positions = place_scopes(data.scopes)
    knowledge_positions = place_knowledge(data.knowledge, scope_positions)
    positions = Map.merge(scope_positions, knowledge_positions)

    %{
      width: @width,
      height: @height,
      nodes: scope_nodes(data, scope_positions) ++ knowledge_nodes(data, knowledge_positions),
      edges: edges(data, positions)
    }
  end

  # Scopes are grouped by depth and spread evenly around their ring. A single
  # scope at a depth is placed on the vertical axis rather than at an arbitrary
  # angle, which keeps a shallow tree looking deliberate instead of lopsided.
  # Within a ring the order is by path, so a scope does not move when a sibling
  # is added elsewhere in the tree.
  defp place_scopes(scopes) do
    scopes
    |> Enum.group_by(&depth(&1.path))
    |> Enum.flat_map(fn {depth, ring} ->
      ring = Enum.sort_by(ring, & &1.path)
      count = length(ring)

      ring
      |> Enum.with_index()
      |> Enum.map(fn {scope, index} ->
        {scope.id, ring_position(depth, index, count)}
      end)
    end)
    |> Map.new()
  end

  # The root sits dead centre; everything else is placed on its depth ring.
  # Angles start at the top of the circle and run clockwise, which is the
  # reading order people expect from a radial diagram.
  defp ring_position(0, 0, 1), do: {@width / 2, @height / 2}

  defp ring_position(depth, index, count) do
    radius = @ring_base + (depth - 1) * @ring_step
    angle = -:math.pi() / 2 + 2 * :math.pi() * index / max(count, 1)

    {clamp(@width / 2 + radius * :math.cos(angle), @width),
     clamp(@height / 2 + radius * :math.sin(angle), @height)}
  end

  # Each statement orbits the scope it lives in. Statements are ordered by id so
  # the picture is stable across reloads, and a scope whose statements exceed
  # one orbit's capacity gains further orbits rather than overlapping.
  #
  # A statement whose scope is not drawn — possible only if a caller hands in
  # inconsistent data — is dropped rather than placed at the origin, where it
  # would look like it belonged to the root.
  defp place_knowledge(knowledge, scope_positions) do
    knowledge
    |> Enum.group_by(& &1.scope_id)
    |> Enum.flat_map(fn {scope_id, items} ->
      case Map.fetch(scope_positions, scope_id) do
        {:ok, {cx, cy}} ->
          items
          |> Enum.sort_by(& &1.id)
          |> Enum.with_index()
          |> Enum.map(fn {item, index} ->
            orbit = div(index, @orbit_capacity)
            slot = rem(index, @orbit_capacity)
            radius = @orbit_base + orbit * @orbit_step

            # Successive orbits are rotated by half a slot so a statement never
            # sits directly behind the one in the orbit inside it.
            angle =
              2 * :math.pi() * slot / @orbit_capacity +
                orbit * :math.pi() / @orbit_capacity

            {item.id,
             {clamp(cx + radius * :math.cos(angle), @width),
              clamp(cy + radius * :math.sin(angle), @height)}}
          end)

        :error ->
          []
      end
    end)
    |> Map.new()
  end

  defp scope_nodes(data, positions) do
    Enum.flat_map(data.scopes, fn scope ->
      case Map.fetch(positions, scope.id) do
        {:ok, {x, y}} ->
          [
            %{
              id: scope.id,
              kind: :scope,
              x: x,
              y: y,
              # The root is drawn larger than its descendants so the centre of
              # the picture reads as the top of the tree.
              r: if(depth(scope.path) == 0, do: 22, else: 16),
              label: scope_label(scope),
              title: scope.path,
              class: "scope depth-#{min(depth(scope.path), 4)}",
              scope_id: scope.id
            }
          ]

        :error ->
          []
      end
    end)
  end

  defp knowledge_nodes(data, positions) do
    Enum.flat_map(data.knowledge, fn item ->
      case Map.fetch(positions, item.id) do
        {:ok, {x, y}} ->
          [
            %{
              id: item.id,
              kind: :knowledge,
              x: x,
              y: y,
              # Radius carries confidence, between 4 and 9 units, so a
              # weakly-held claim reads as a smaller dot without needing a
              # legend to decode a colour.
              r: 4.0 + 5.0 * min(max(item.confidence, 0.0), 1.0),
              label: nil,
              title: item.statement,
              class: "knowledge state-#{item.state}",
              scope_id: item.scope_id
            }
          ]

        :error ->
          []
      end
    end)
  end

  defp edges(data, positions) do
    containment =
      Enum.map(data.containment, fn {parent_id, child_id} ->
        {:containment, parent_id, child_id}
      end)

    membership = Enum.map(data.knowledge, &{:membership, &1.scope_id, &1.id})

    scope_relations =
      Enum.map(data.relations, &{:scope_relation, &1.source_scope_id, &1.target_scope_id})

    knowledge_relations =
      Enum.map(
        data.knowledge_edges,
        &{:knowledge_relation, &1.source_knowledge_id, &1.target_knowledge_id}
      )

    (containment ++ membership ++ scope_relations ++ knowledge_relations)
    |> Enum.flat_map(fn {kind, from_id, to_id} ->
      with {:ok, {x1, y1}} <- Map.fetch(positions, from_id),
           {:ok, {x2, y2}} <- Map.fetch(positions, to_id) do
        [%{kind: kind, x1: x1, y1: y1, x2: x2, y2: y2}]
      else
        :error -> []
      end
    end)
  end

  # The last path segment is what distinguishes a scope from its siblings; the
  # full path is in the tooltip. The root has no last segment, so it is named.
  defp scope_label(%{path: "/"}), do: "root"
  defp scope_label(scope), do: scope.key

  defp depth("/"), do: 0
  defp depth(path), do: path |> String.split("/", trim: true) |> length()

  # Keeps a node inside the frame. A margin equal to the largest node radius
  # plus its stroke means a clamped node is still drawn whole rather than
  # sliced by the viewBox edge.
  defp clamp(value, extent) do
    value |> max(28.0) |> min(extent - 28.0)
  end
end
