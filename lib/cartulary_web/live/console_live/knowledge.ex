# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.ConsoleLive.Knowledge do
  @moduledoc """
  `/console/knowledge` browsing and retrieval for authorized statements.

  Browsing exhaustively filters stored rows; retrieval ranks candidates and
  reports contributed and deadline-dropped strategies. Retrieval requires an
  explicit scope. URL query parameters hold all filters and pagination.

  Loader visibility, Ash policies, and row-level security authorize results;
  page filters may only narrow them.
  """

  use CartularyWeb, :live_view

  import CartularyWeb.ConsoleComponents

  alias Cartulary.Memory
  alias CartularyWeb.Console.Access
  alias CartularyWeb.Console.Loader

  # Allowlist query keys before building loader filters.
  @filter_keys ~w(scope state kind sensitivity target_level subject page q)

  @doc """
  Mounts empty; `handle_params/3` loads initial and patched URLs identically.
  """
  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :search, nil)}
  end

  @doc """
  Loads URL-filtered browsing results and an optional scoped retrieval preview.
  """
  @impl true
  def handle_params(params, _uri, socket) do
    filters = Map.take(params, @filter_keys)
    result = Loader.knowledge_list(socket.assigns.current_actor, filters)

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:result, result)
     |> assign(:search, retrieval_preview(socket.assigns.current_actor, filters))}
  end

  @doc """
  Writes non-blank filters to the URL and resets pagination.
  """
  @impl true
  def handle_event("filter", params, socket) do
    filters =
      params
      |> Map.take(@filter_keys)
      |> Map.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.delete("page")

    {:noreply, push_patch(socket, to: ~p"/console/knowledge?#{filters}")}
  end

  def handle_event("clear", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/console/knowledge")}
  end

  @doc """
  Renders the filter bar, the optional retrieval preview, and the paged list.
  """
  @impl true
  def render(assigns) do
    ~H"""
    <.shell actor={@current_actor} active={:knowledge} title="Knowledge" flash={@flash}>
      <:subtitle>
        Every governed statement your roles reach. Browsing enumerates; retrieval ranks.
        They answer different questions, so both are shown.
      </:subtitle>

      <.panel
        title="Filter"
        description="Scope filters include everything contained in that scope, because context flows down the tree."
      >
        <form phx-change="filter" phx-submit="filter" class="filters">
          <label>
            Scope
            <select name="scope">
              <option value="">All scopes you can read</option>
              <option :for={scope <- @result.scopes} value={scope.path} selected={@filters["scope"] == scope.path}>
                {scope.path}
              </option>
            </select>
          </label>

          <label>
            State
            <select name="state">
              <option value="">Any visible state</option>
              <option
                :for={state <- Access.visible_states(@current_actor)}
                value={state}
                selected={@filters["state"] == state}
              >
                {state}
              </option>
            </select>
          </label>

          <label>
            Kind
            <select name="kind">
              <option value="">Any kind</option>
              <option :for={kind <- ~w(fact preference event relation skill)} value={kind} selected={@filters["kind"] == kind}>
                {kind}
              </option>
            </select>
          </label>

          <label>
            Sensitivity
            <select name="sensitivity">
              <option value="">Any sensitivity</option>
              <option
                :for={level <- ~w(public internal personal restricted)}
                value={level}
                selected={@filters["sensitivity"] == level}
              >
                {level}
              </option>
            </select>
          </label>

          <label>
            Subject
            <select name="subject">
              <option value="">Anyone</option>
              <option value="me" selected={@filters["subject"] == "me"}>About me</option>
            </select>
          </label>

          <label class="grow">
            Retrieval query
            <input
              name="q"
              value={@filters["q"]}
              placeholder="Ask retrieval what it would find"
              autocomplete="off"
            />
          </label>

          <button type="button" class="ghost" phx-click="clear">Clear</button>
        </form>

        <p :if={@filters["q"] not in [nil, ""] and @filters["scope"] in [nil, ""]} class="hint">
          Retrieval searches one scope and everything above it, so pick a scope to run it.
          The filters above still apply to the list below.
        </p>
      </.panel>

      <.panel
        :if={@search}
        title="Retrieval preview"
        description="What the retrieval engine would return for this query, and how it got there. Ranked, not exhaustive."
      >
        <div class="tiles compact">
          <.tile label="Profile" value={@search["profile"]} note={@search["profile_version"]} />
          <.tile label="Latency" value={"#{@search["latency_ms"]} ms"} />
          <.tile label="Candidates" value={length(@search["candidates"])} />
          <.tile
            label="Strategies used"
            value={length(@search["contributed_strategies"])}
            note={strategy_note(@search)}
            tone={strategy_tone(@search)}
          />
        </div>

        <.empty
          :if={@search["candidates"] == []}
          message="Retrieval found nothing for that query in this scope. That is a ranking result, not proof the memory is empty — the list below is the exhaustive one."
        />

        <table :if={@search["candidates"] != []} class="grid">
          <thead>
            <tr>
              <th>#</th>
              <th>Candidate</th>
              <th>Source</th>
              <th>Score</th>
              <th>Found by</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={candidate <- @search["candidates"]}>
              <td class="nowrap">{candidate.rank}</td>
              <td>{truncate(candidate.record["statement"], 160)}</td>
              <td class="nowrap">
                <.badge family="kind" value={candidate.record["candidate_type"] || "knowledge"} />
                <.id_chip
                  :if={candidate.record["candidate_type"] in [nil, "knowledge"]}
                  value={candidate.id}
                  navigate={~p"/console/knowledge/#{candidate.id}"}
                />
              </td>
              <td class="nowrap">{Float.round(candidate.score * 1.0, 4)}</td>
              <td class="muted">{Enum.join(candidate.evidence["strategies"] || [], ", ")}</td>
            </tr>
          </tbody>
        </table>
      </.panel>

      <.panel
        title={"#{@result.total} statement(s)"}
        description="Ordered by confidence, then recency. Confidence is how sure the system is; it is independent of how widely the statement may travel."
      >
        <.empty
          :if={@result.items == []}
          message="Nothing matches these filters. A reader with no role on a scope sees none of its statements, which is the intended result rather than an error."
        />

        <table :if={@result.items != []} class="grid">
          <thead>
            <tr>
              <th>Statement</th>
              <th>Scope</th>
              <th>Kind</th>
              <th>State</th>
              <th>Sensitivity</th>
              <th>Confidence</th>
              <th>Recorded</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={item <- @result.items}>
              <td>
                <.link navigate={~p"/console/knowledge/#{item.id}"} class="statement-link">
                  {truncate(item.statement, 180)}
                </.link>
              </td>
              <td class="nowrap">{item.scope_path || "(unreadable scope)"}</td>
              <td><.badge family="kind" value={item.kind} /></td>
              <td><.badge family="state" value={item.state} /></td>
              <td><.badge family="sensitivity" value={item.sensitivity} /></td>
              <td class="nowrap">{Float.round(item.confidence * 1.0, 2)}</td>
              <td class="nowrap muted">{timestamp(item.inserted_at)}</td>
            </tr>
          </tbody>
        </table>

        <nav :if={@result.total > @result.page_size} class="pager">
          <.link
            :if={@result.page > 1}
            patch={~p"/console/knowledge?#{page_params(@filters, @result.page - 1)}"}
          >
            ← Previous
          </.link>
          <span>Page {@result.page} of {page_count(@result)}</span>
          <.link
            :if={@result.page < page_count(@result)}
            patch={~p"/console/knowledge?#{page_params(@filters, @result.page + 1)}"}
          >
            Next →
          </.link>
        </nav>
      </.panel>
    </.shell>
    """
  end

  # Retrieval requires an explicit query and scope; no scope is not the root.
  defp retrieval_preview(actor, %{"q" => query, "scope" => scope})
       when is_binary(query) and query != "" and is_binary(scope) and scope != "" do
    Memory.search(%{"query" => query, "scope_path" => scope}, actor)
  end

  defp retrieval_preview(_actor, _filters), do: nil

  # Separate deadline loss from empty indexes, and both from a healthy run. A search where the
  # text-reading strategies all found nothing still returns a full page — of whatever is most
  # recent — so the count above cannot be read alone.
  defp strategy_note(search) do
    case Enum.reject(
           [
             strategy_group("dropped", search["dropped_strategies"]),
             strategy_group("found nothing", search["empty_strategies"])
           ],
           &is_nil/1
         ) do
      [] -> "all contributed"
      notes -> Enum.join(notes, "; ")
    end
  end

  defp strategy_group(_label, []), do: nil
  defp strategy_group(label, names), do: "#{label}: " <> Enum.map_join(names, ", ", &to_string/1)

  defp strategy_tone(search) do
    if search["dropped_strategies"] == [] and search["empty_strategies"] == [],
      do: "neutral",
      else: "warn"
  end

  defp page_params(filters, page), do: Map.put(filters, "page", Integer.to_string(page))

  defp page_count(%{total: total, page_size: size}) do
    max(ceil(total / size), 1)
  end
end
