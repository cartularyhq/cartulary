# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.Console.GraphTest do
  @moduledoc """
  Pins the graph layout's two load-bearing properties: it is a pure function of
  its input, and it draws nothing it was not given.

  Determinism matters because the picture is a navigation aid. A reader who
  finds a statement in the lower left and comes back to it must find it in the
  same place; a layout that moved on every render would make the graph
  decorative rather than useful. It is also why the layout uses no randomness
  and no wall clock — either would break resumability as well as this test.

  The second property is a disclosure guard. The graph is built from scopes,
  scope relations, statements, and statement relations, and from nothing else.
  Entity rows in particular are a private recall cache whose rows span every
  scope that mentioned a name, so a future change that added them as nodes
  would carry names across the boundary the scope tree exists to keep.
  """

  use ExUnit.Case, async: true

  alias CartularyWeb.Console.Graph

  describe "build/1" do
    test "is a pure function of its input" do
      data = sample()

      assert Graph.build(data) == Graph.build(data)
    end

    test "places the root scope at the centre of the frame" do
      layout = Graph.build(sample())
      root = Enum.find(layout.nodes, &(&1.title == "/"))

      assert root.x == layout.width / 2
      assert root.y == layout.height / 2
    end

    test "keeps every node inside the frame" do
      layout = Graph.build(sample())

      for node <- layout.nodes do
        assert node.x >= 0 and node.x <= layout.width
        assert node.y >= 0 and node.y <= layout.height
      end
    end

    test "statement radius grows with confidence" do
      layout = Graph.build(sample())
      weak = Enum.find(layout.nodes, &(&1.id == "k-weak"))
      strong = Enum.find(layout.nodes, &(&1.id == "k-strong"))

      assert strong.r > weak.r
    end

    test "draws containment, membership, and both relation kinds" do
      kinds =
        sample() |> Graph.build() |> Map.fetch!(:edges) |> Enum.map(& &1.kind) |> Enum.uniq()

      assert :containment in kinds
      assert :membership in kinds
      assert :scope_relation in kinds
      assert :knowledge_relation in kinds
    end

    test "drops an edge whose endpoint is not drawn" do
      # A line to a node that is not on the page would disclose that an unseen
      # node exists. The loader filters these already; this asserts the layout
      # refuses them too, so neither layer alone is the only guard.
      data = %{sample() | knowledge_edges: [relation("k-strong", "not-drawn")]}

      refute Enum.any?(Graph.build(data).edges, &(&1.kind == :knowledge_relation))
    end

    test "renders no entity node and no entity field" do
      layout = Graph.build(sample())

      refute Enum.any?(layout.nodes, &(&1.kind == :entity))
      refute Enum.any?(layout.nodes, &Map.has_key?(&1, :entity_id))
      assert Enum.all?(layout.nodes, &(&1.kind in [:scope, :knowledge]))
    end
  end

  # Two scopes, one relation between them, two statements of differing
  # confidence, and one relation between the statements — the smallest input
  # that exercises every node and edge kind at once.
  defp sample do
    %{
      scopes: [
        %{id: "s-root", path: "/", key: "root", name: "root", state: "active", parent_id: nil},
        %{
          id: "s-team",
          path: "/team",
          key: "team",
          name: "Team",
          state: "active",
          parent_id: "s-root"
        },
        %{
          id: "s-ops",
          path: "/ops",
          key: "ops",
          name: "Ops",
          state: "active",
          parent_id: "s-root"
        }
      ],
      knowledge: [
        knowledge("k-weak", "s-team", 0.2, "active"),
        knowledge("k-strong", "s-team", 0.95, "proposed")
      ],
      containment: [{"s-root", "s-team"}, {"s-root", "s-ops"}],
      relations: [%{source_scope_id: "s-team", target_scope_id: "s-ops", kind: "related"}],
      knowledge_edges: [relation("k-weak", "k-strong")],
      scope_paths: %{"s-root" => "/", "s-team" => "/team", "s-ops" => "/ops"},
      all_scopes: [],
      truncated?: false
    }
  end

  defp knowledge(id, scope_id, confidence, state) do
    %{
      id: id,
      scope_id: scope_id,
      confidence: confidence,
      state: state,
      statement: "statement #{id}",
      kind: "fact",
      sensitivity: "internal",
      scope_path: "/team"
    }
  end

  defp relation(source, target) do
    %{source_knowledge_id: source, target_knowledge_id: target, kind: "supports"}
  end
end
