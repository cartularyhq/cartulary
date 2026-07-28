# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.ConsoleLive.Scopes do
  @moduledoc """
  The scope directory at `/console/scopes`: the containment tree as a
  browsable hierarchy, with what lives in each node and what authority the
  reader holds there.

  ## Why the tree is the important picture

  Almost everything in Cartulary hangs off a scope, and three rules follow from
  the tree's shape. This page exists to make all three visible rather than
  merely documented:

  - **Context flows down.** A statement recorded at `/team` is in context at
    `/team/project`, and never the other way round. Moving knowledge upward is
    a governed decision, not a consequence of the tree.
  - **Nearest wins.** Where several ancestors offer a value for the same thing
    — a retrieval override, a skill requirement, a role — the nearest enclosing
    scope wins, so a specific place can always override a general one.
  - **Deny wins.** Any applicable deny grant removes a scope outright. It is
    not weighed against allows and cannot be out-ranked by a stronger role,
    which is what makes a deny a dependable hole in a broad inherited grant.

  ## What is shown, and what absence means

  Only scopes the reader's grants reach appear. A subtree that is missing is
  not empty — it is invisible, and the two are deliberately indistinguishable
  from here.

  A scope whose parent is invisible still appears at its own depth. Access is
  granted per scope, so a hidden intermediate must not hide a granted child;
  the indentation therefore reflects path depth rather than the chain of
  visible ancestors.

  ## Relations are not grants

  Scope relations link scopes that are not in a parent-child line. They can
  widen what retrieval *considers*, but never what a reader may *see*:
  expansion across a relation happens only when the caller is already
  authorized at both ends. They are listed separately from the tree so that
  distinction stays obvious.

  This page performs no writes.
  """

  use CartularyWeb, :live_view

  import CartularyWeb.ConsoleComponents

  alias CartularyWeb.Console.Loader

  @doc """
  Loads the tree, the lateral relations, and the recent role grants.
  """
  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :directory, Loader.scope_directory(socket.assigns.current_actor))}
  end

  @doc """
  Renders the directory, the relations, and the grants that produced the
  reader's access.
  """
  @impl true
  def render(assigns) do
    ~H"""
    <.shell actor={@current_actor} active={:scopes} title="Scopes" flash={@flash}>
      <:subtitle>
        The containment tree. Context flows down it, the nearest scope wins where two
        disagree, and any applicable deny removes a scope outright.
      </:subtitle>

      <.panel
        title="Directory"
        description="Counts are of what is attached directly to each scope, not to its descendants. A scope you cannot read is absent rather than shown empty."
      >
        <.empty
          :if={@directory.rows == []}
          message="No scope is reachable with your current grants."
        />

        <table :if={@directory.rows != []} class="grid tree">
          <thead>
            <tr>
              <th>Scope</th>
              <th>Your role</th>
              <th>State</th>
              <th>Statements</th>
              <th>Documents</th>
              <th>Sessions</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @directory.rows}>
              <td>
                <span class={"indent-#{min(row.depth, 6)}"}>
                  <span class="tree-glyph" aria-hidden="true">{tree_glyph(row.depth)}</span>
                  <.link navigate={~p"/console/knowledge?#{[scope: row.scope.path]}"}>
                    {row.scope.path}
                  </.link>
                </span>
                <span :if={row.scope.name != row.scope.key} class="muted">{row.scope.name}</span>
              </td>
              <td>
                <.badge :if={row.role} family="kind" value={row.role} />
                <span :if={is_nil(row.role)} class="muted">inherited</span>
              </td>
              <td><.badge family="state" value={row.scope.state} /></td>
              <td class="nowrap">{row.knowledge_count}</td>
              <td class="nowrap">{row.document_count}</td>
              <td class="nowrap">{row.session_count}</td>
            </tr>
          </tbody>
        </table>
      </.panel>

      <.panel
        title="Relations"
        description="Lateral links between scopes that are not in a parent-child line. A relation can widen what retrieval considers; it never widens what you may see."
      >
        <.empty :if={@directory.relations == []} message="No scope relations are defined." />
        <table :if={@directory.relations != []} class="grid">
          <thead>
            <tr>
              <th>From</th>
              <th>To</th>
              <th>Kind</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={relation <- @directory.relations}>
              <td>{scope_path(@directory.scope_paths, relation.source_scope_id)}</td>
              <td>{scope_path(@directory.scope_paths, relation.target_scope_id)}</td>
              <td><.badge family="kind" value={relation.kind} /></td>
            </tr>
          </tbody>
        </table>
      </.panel>

      <.panel
        title="Role grants"
        description="One peer's role at one scope. A propagating grant reaches every scope contained in it; a deny removes access wherever it applies, whatever else was granted."
      >
        <.empty :if={@directory.grants == []} message="No role grants are visible to you." />
        <table :if={@directory.grants != []} class="grid">
          <thead>
            <tr>
              <th>Scope</th>
              <th>Peer</th>
              <th>Role</th>
              <th>Effect</th>
              <th>Propagates</th>
              <th>Granted</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={grant <- @directory.grants}>
              <td>{scope_path(@directory.scope_paths, grant.scope_id)}</td>
              <td><.id_chip value={grant.peer_id} /></td>
              <td><.badge family="kind" value={grant.role} /></td>
              <td><.badge family="decision" value={grant.effect} /></td>
              <td>{if grant.propagate, do: "yes", else: "no"}</td>
              <td class="nowrap muted">{timestamp(grant.granted_at)}</td>
            </tr>
          </tbody>
        </table>
      </.panel>
    </.shell>
    """
  end

  # A leading glyph makes depth legible even when the indentation is compressed
  # on a narrow screen. The root carries a different mark from its descendants
  # because it is the one scope with no parent.
  defp tree_glyph(0), do: "●"
  defp tree_glyph(_depth), do: "└"
end
