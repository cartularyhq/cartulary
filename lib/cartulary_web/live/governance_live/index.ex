# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.GovernanceLive.Index do
  use CartularyWeb, :live_view

  alias Cartulary.DataLayer
  alias Cartulary.Governance.Engine
  alias Cartulary.Governance.ValidationItem
  alias Cartulary.Knowledge.KnowledgeItem

  require Ash.Query

  @impl true
  def mount(_params, _session, socket) do
    {:ok, load_queue(socket)}
  end

  @impl true
  def handle_event("decide", %{"id" => id, "action" => action} = params, socket) do
    opts =
      params
      |> Map.take(["statement", "merge_into_id", "defer_hours", "sensitivity"])
      |> Map.reject(fn {_key, value} -> value in [nil, ""] end)

    Engine.decide(socket.assigns.current_actor, id, action, opts)
    {:noreply, load_queue(socket)}
  end

  def handle_event(
        "decide",
        %{"validation_id" => id, "action" => _action} = params,
        socket
      ) do
    handle_event("decide", Map.put(params, "id", id), socket)
  end

  def handle_event("bulk", %{"action" => action} = params, socket) do
    ids = params |> Map.get("ids", %{}) |> Map.keys()
    Engine.bulk_decide(socket.assigns.current_actor, ids, action)
    {:noreply, load_queue(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="font-family: system-ui; max-width: 1100px; margin: 2rem auto; padding: 0 1rem;">
      <header style="display:flex; align-items:center; justify-content:space-between;">
        <div>
          <h1>Governance queue</h1>
          <p>Gate A/B proposals, conflicts, consent holds, and lifecycle reviews.</p>
        </div>
        <form method="post" action="/governance/sign-out">
          <input type="hidden" name="_method" value="delete" />
          <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
          <button>Sign out</button>
        </form>
      </header>

      <form id="bulk-form" phx-submit="bulk">
        <div style="display:flex; gap:.5rem; margin:1rem 0;">
          <button name="action" value="approve">Approve selected</button>
          <button name="action" value="reject">Reject selected</button>
          <button name="action" value="defer">Defer selected</button>
        </div>
      </form>

      <p :if={@items == []}>The queue is clear.</p>

      <article
        :for={item <- @items}
        style="border:1px solid #d0d7de; border-radius:8px; padding:1rem; margin:1rem 0;"
      >
        <div style="display:flex; gap:.75rem; align-items:start;">
          <input
            type="checkbox"
            form="bulk-form"
            name={"ids[#{item.id}]"}
            value="true"
          />
          <div style="flex:1;">
            <p><strong>{item.knowledge.statement}</strong></p>
            <dl style="display:grid; grid-template-columns:10rem 1fr; gap:.25rem;">
              <dt>Gate / target</dt><dd>{item.kind} / {item.target_level}</dd>
              <dt>Confidence</dt><dd>{item.confidence}</dd>
              <dt>Sensitivity</dt><dd>{item.sensitivity}</dd>
              <dt>State / due</dt><dd>{item.state} / {item.due_at}</dd>
              <dt>Provenance IDs</dt><dd>{Enum.join(item.provenance_ids, ", ")}</dd>
              <dt>Conflicts</dt><dd>{Enum.join(item.conflict_knowledge_ids, ", ")}</dd>
            </dl>

            <div style="display:flex; flex-wrap:wrap; gap:.5rem; margin-top:1rem;">
              <button type="button" phx-click="decide" phx-value-id={item.id} phx-value-action="approve">
                Approve
              </button>
              <button type="button" phx-click="decide" phx-value-id={item.id} phx-value-action="reject">
                Reject
              </button>
              <button type="button" phx-click="decide" phx-value-id={item.id} phx-value-action="defer">
                Defer
              </button>
            </div>

            <form phx-submit="decide" style="display:flex; gap:.5rem; margin-top:.75rem;">
              <input type="hidden" name="validation_id" value={item.id} />
              <input type="hidden" name="action" value="edit" />
              <input name="statement" value={item.knowledge.statement} style="flex:1;" />
              <button>Edit as replacement</button>
            </form>

            <form phx-submit="decide" style="display:flex; gap:.5rem; margin-top:.75rem;">
              <input type="hidden" name="validation_id" value={item.id} />
              <input type="hidden" name="action" value="merge" />
              <input name="merge_into_id" placeholder="Knowledge ID to merge into" style="flex:1;" />
              <button>Merge</button>
            </form>
          </div>
        </div>
      </article>
    </div>
    """
  end

  defp load_queue(socket) do
    items =
      DataLayer.with_actor(socket.assigns.current_actor, fn account, actor ->
        validations =
          ValidationItem
          |> Ash.Query.filter(state in ["pending", "deferred", "awaiting_consent", "escalated"])
          |> Ash.Query.sort(due_at: :asc)
          |> Ash.Query.set_tenant(account.id)
          |> Ash.read!(actor: actor)

        Enum.map(validations, fn item ->
          knowledge =
            KnowledgeItem
            |> Ash.Query.filter(id == ^item.knowledge_id)
            |> Ash.Query.set_tenant(account.id)
            |> Ash.read_one!(actor: actor)

          Map.put(item, :knowledge, knowledge)
        end)
      end)

    assign(socket, :items, items)
  end
end
