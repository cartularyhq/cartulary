# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.ConsoleLive.Knowledge do
  @moduledoc """
  The knowledge explorer at `/console/knowledge`: every governed statement the
  reader may see, filtered, paged, and cross-linked.

  ## Two ways to look, and they are not the same thing

  **Browsing** applies plain attribute filters — scope subtree, lifecycle state,
  kind, sensitivity, target level, subject — and pages through the result in a
  stable order. It is exhaustive: what is not shown is either filtered out or
  not visible to this reader, never merely ranked low.

  **Retrieval** runs the same multi-strategy engine that answers an agent's
  `search` call, and shows its working: which strategies contributed, which
  were dropped against the deadline, how much they disagreed, and what each
  candidate scored. It is *not* exhaustive and is not meant to be. Presenting
  the two side by side is deliberate — it is the difference between "what is
  stored" and "what would be found", and conflating them is how people come to
  believe a retrieval miss means the memory is empty.

  Retrieval needs a scope to search from, because context flows down the
  containment tree: searching at `/team/project` also searches `/team` and the
  root, and there is no "search everywhere" that would ignore that shape. When
  no scope is chosen the search box says so rather than quietly guessing one.

  ## Filters live in the URL

  Every filter and the page number are query parameters, applied through
  `handle_params/3`. A view is therefore linkable and survives a reload, and
  the back button behaves the way a reader expects. Do not move a filter into
  socket state only: it becomes invisible to the address bar and to anyone the
  reader sends the link to.

  ## Visibility

  This module applies no access rule of its own. The lifecycle-state and
  provisional rules are compiled into the query by the loader, and Ash policies
  plus row-level security decide scope and Account. A filter here can only ever
  narrow what those already allowed.
  """

  use CartularyWeb, :live_view

  import CartularyWeb.ConsoleComponents

  alias Cartulary.Memory
  alias CartularyWeb.Console.Access
  alias CartularyWeb.Console.Loader

  # The filter keys this page understands. Anything else in the query string is
  # ignored rather than passed through, so a hand-edited URL cannot smuggle an
  # unexpected term into the query the loader builds.
  @filter_keys ~w(scope state kind sensitivity target_level subject page q)

  @doc """
  Mounts with no data. Everything is loaded in `handle_params/3`, which runs on
  the initial render as well as on every subsequent patch, so the load path is
  identical whether a reader arrives with filters in the URL or applies them
  afterwards.
  """
  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :search, nil)}
  end

  @doc """
  Reads the filters out of the URL and loads the matching page.

  Runs a retrieval preview as well when the reader supplied both a query string
  and a scope to search from. Retrieval is a separate call from the browse
  listing on purpose: it ranks rather than enumerates, and its result is
  displayed as its own panel so the two are never mistaken for each other.
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
  Handles the filter form and the search box.

  Both push the reader to a new URL rather than mutating socket state, so the
  address bar always describes what is on screen. Blank fields are dropped from
  the URL instead of being sent as empty strings, which keeps a shared link
  short and keeps "no filter" distinguishable from "filter for nothing".

  Applying a filter resets to the first page. Keeping the old page number would
  land a reader on page four of a two-page result and look like an empty
  Account.
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
            tone={if @search["dropped_strategies"] == [], do: "neutral", else: "warn"}
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

  # Retrieval runs only when the reader gave both a query and a scope to search
  # from. There is no default scope: picking one silently would make the result
  # depend on a choice the reader never saw, and "no scope" is not the same as
  # "the root" — the root's own path resolves to a historical default scope.
  defp retrieval_preview(actor, %{"q" => query, "scope" => scope})
       when is_binary(query) and query != "" and is_binary(scope) and scope != "" do
    Memory.search(%{"query" => query, "scope_path" => scope}, actor)
  end

  defp retrieval_preview(_actor, _filters), do: nil

  # Names the dropped strategies rather than only counting them. A strategy
  # that ran out of deadline is why a result looks thin, and a reader who
  # cannot see which one was dropped has no way to tell a slow index from an
  # empty one.
  defp strategy_note(%{"dropped_strategies" => []}), do: "none dropped"

  defp strategy_note(%{"dropped_strategies" => dropped}) do
    "dropped: " <> Enum.map_join(dropped, ", ", &to_string/1)
  end

  defp page_params(filters, page), do: Map.put(filters, "page", Integer.to_string(page))

  defp page_count(%{total: total, page_size: size}) do
    max(ceil(total / size), 1)
  end
end
