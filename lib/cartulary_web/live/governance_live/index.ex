# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.GovernanceLive.Index do
  use CartularyWeb, :live_view

  alias Cartulary.DataLayer
  alias Cartulary.Governance.Engine
  alias Cartulary.Governance.ValidationItem
  alias Cartulary.Knowledge.KnowledgeItem
  alias Cartulary.Skills
  alias Cartulary.Skills.SkillRequirementCard
  alias Cartulary.Topology.Scope

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

  def handle_event("publish_skill_card", params, socket) do
    with {:ok, requirements} <- Jason.decode(params["requirements"]),
         {:ok, card} <-
           Skills.publish(socket.assigns.current_actor, %{
             scope_path: params["scope_path"],
             skill_key: params["skill_key"],
             description: params["description"],
             requirements: requirements
           }) do
      socket =
        socket
        |> put_flash(:info, "Published #{card.skill_key} version #{card.version}.")
        |> load_queue()

      {:noreply, socket}
    else
      {:error, %Jason.DecodeError{}} ->
        {:noreply, put_flash(socket, :error, "Requirements must be valid JSON.")}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, to_string(message))}
    end
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

      <section style="border-top:2px solid #d0d7de; margin-top:2rem; padding-top:1.5rem;">
        <h2>Skill requirement cards</h2>
        <p>
          Author and review versioned procedural-memory contracts. Child scopes override
          inherited requirements by requirement key.
        </p>

        <form phx-submit="publish_skill_card" style="display:grid; gap:.75rem; margin:1rem 0;">
          <label>
            Scope path
            <input name="scope_path" placeholder="/marketing/social" required style="width:100%;" />
          </label>
          <label>
            Skill key
            <input name="skill_key" placeholder="write-copy" required style="width:100%;" />
          </label>
          <label>
            Description
            <input name="description" placeholder="Knowledge needed before writing copy" style="width:100%;" />
          </label>
          <label>
            Requirements (`f9-1` JSON)
            <textarea name="requirements" rows="12" required style="width:100%;">{skill_card_example()}</textarea>
          </label>
          <button>Publish new version</button>
        </form>

        <p :if={@skill_cards == []}>No skill cards have been authored.</p>

        <article
          :for={card <- @skill_cards}
          style="border:1px solid #d0d7de; border-radius:8px; padding:1rem; margin:1rem 0;"
        >
          <p>
            <strong>{card.skill_key}</strong>
            · {card.scope_path}
            · version {card.version}
            · {card.requirement_schema_version}
            · {if(card.active, do: "active", else: "retired")}
          </p>
          <p :if={card.description}>{card.description}</p>
          <pre style="overflow:auto; white-space:pre-wrap;">{Jason.encode!(card.requirements, pretty: true)}</pre>
        </article>
      </section>
    </div>
    """
  end

  defp load_queue(socket) do
    {items, skill_cards} =
      DataLayer.with_actor(socket.assigns.current_actor, fn account, actor ->
        validations =
          ValidationItem
          |> Ash.Query.filter(state in ["pending", "deferred", "awaiting_consent", "escalated"])
          |> Ash.Query.sort(due_at: :asc)
          |> Ash.Query.set_tenant(account.id)
          |> Ash.read!(actor: actor)

        items =
          Enum.map(validations, fn item ->
            knowledge =
              KnowledgeItem
              |> Ash.Query.filter(id == ^item.knowledge_id)
              |> Ash.Query.set_tenant(account.id)
              |> Ash.read_one!(actor: actor)

            Map.put(item, :knowledge, knowledge)
          end)

        scope_paths =
          Scope
          |> Ash.Query.set_tenant(account.id)
          |> Ash.read!(actor: actor)
          |> Map.new(&{&1.id, &1.path})

        skill_cards =
          SkillRequirementCard
          |> Ash.Query.sort(skill_key: :asc, version: :desc)
          |> Ash.Query.set_tenant(account.id)
          |> Ash.read!(actor: actor)
          |> Enum.map(&Map.put(&1, :scope_path, Map.fetch!(scope_paths, &1.scope_id)))

        {items, skill_cards}
      end)

    socket
    |> assign(:items, items)
    |> assign(:skill_cards, skill_cards)
  end

  defp skill_card_example do
    Jason.encode!(
      [
        %{
          "key" => "brand-voice",
          "description" => "Current brand voice",
          "selector" => %{"kind" => "preference", "subject" => "scope"},
          "level" => "required",
          "source_policy" => "either",
          "freshness" => %{"revalidated_within_seconds" => 2_592_000},
          "prompt" => "How should this scope's brand voice sound?"
        }
      ],
      pretty: true
    )
  end
end
