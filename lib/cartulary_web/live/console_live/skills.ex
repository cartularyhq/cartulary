# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.ConsoleLive.Skills do
  @moduledoc """
  Procedural memory at `/console/skills`: the requirement cards that say what
  must already be known before a skill runs, and a live check of whether it is.

  ## Cards are authored configuration, not knowledge

  This is the distinction the page is built around. Knowledge is extracted from
  observations and has to clear the governance gates before anyone sees it. A
  card is written by a person, takes effect the moment it is published, and is
  versioned plainly: publishing inserts a new immutable version and retires the
  previous one. A card never enters the gates, and — just as importantly — a
  card can never *satisfy* a requirement. Only governed knowledge can, so an
  author cannot declare a skill ready by writing a card that answers itself.

  Every version is listed, not only the active one. A retired version is the
  record of what a skill used to demand, and is what makes an old readiness
  result readable after the fact. Exactly one version per scope and skill key
  is active; the rest are never consulted.

  ## Requirements inherit, nearest scope wins

  Requirements merge by key down the containment tree. A child scope can
  override an inherited requirement by reusing its key, add new keys, or switch
  an inherited key off. Descendants therefore carry no copies of their
  ancestors' cards, which is why reading a single card does not tell you what a
  deep scope actually demands — the readiness check does.

  ## The readiness check is metadata only

  It runs no model, no text search, and no reasoning: it compares stored fields
  against each requirement's selector. Only authorized `active` knowledge, or
  the checked peer's own usable `provisional` knowledge, can satisfy one.
  Expired and revalidation-due items count as gaps immediately, without waiting
  for a background sweep, so a delayed job cannot open a window where a stale
  answer looks current.

  A gap is not permission to write the missing fact. An elicited answer has to
  return through ordinary observation ingest and pass the gates before
  readiness improves.

  ## Authoring lives elsewhere

  Publishing a card is a curator act and stays on the curator queue page. This
  page reads and checks; it publishes nothing.
  """

  use CartularyWeb, :live_view

  import CartularyWeb.ConsoleComponents

  alias Cartulary.Skills
  alias CartularyWeb.Console.Access
  alias CartularyWeb.Console.Loader

  @doc """
  Loads every card version the reader may see, with no readiness report until
  one is asked for.
  """
  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:skills, Loader.skills(socket.assigns.current_actor))
     |> assign(:report, nil)}
  end

  @doc """
  Runs one readiness check for the signed-in reader.

  The peer checked is always the reader themselves. Checking somebody else's
  readiness would disclose which knowledge exists about them in scopes the
  reader may not hold, so the console does not offer it even to an
  administrator; the JSON surface, which agents use to check their own peer,
  is where a different peer can be named.

  A missing skill, an unknown scope, or a scope the reader cannot see raises in
  the operation layer. That is reported as a flash rather than crashing the
  socket, because both fields are typed by hand and a typo is an ordinary
  mistake.
  """
  @impl true
  def handle_event("check", %{"skill" => skill, "scope_path" => scope_path}, socket) do
    socket =
      try do
        report =
          Skills.check_readiness(socket.assigns.current_actor, %{
            "skill" => skill,
            "scope_path" => scope_path
          })

        assign(socket, :report, report)
      rescue
        error in [ArgumentError, Ash.Error.Forbidden, Ash.Error.Query.NotFound] ->
          _ = error

          socket
          |> assign(:report, nil)
          |> put_flash(:error, "No such skill or scope, or you cannot read that scope.")
      end

    {:noreply, socket}
  end

  @doc """
  Renders the readiness form, its result, and the card library.
  """
  @impl true
  def render(assigns) do
    ~H"""
    <.shell actor={@current_actor} active={:skills} title="Skills" flash={@flash}>
      <:subtitle>
        What must already be known before a skill runs, and whether you know it yet.
        Requirements inherit down the scope tree, nearest scope winning.
      </:subtitle>

      <.panel
        title="Check your readiness"
        description="A pure metadata evaluation against the knowledge you are authorized to use. No model runs, and nothing is written."
      >
        <form phx-submit="check" class="filters">
          <label class="grow">
            Skill key
            <input name="skill" placeholder="write-copy" required autocomplete="off" />
          </label>
          <label class="grow">
            Scope
            <select name="scope_path" required>
              <option :for={scope <- @skills.scopes} value={scope.path}>{scope.path}</option>
            </select>
          </label>
          <button class="primary">Check</button>
        </form>

        <div :if={@report} class="report">
          <div class="tiles compact">
            <.tile
              label="Ready"
              value={if @report["ready"], do: "yes", else: "no"}
              tone={if @report["ready"], do: "accent", else: "warn"}
            />
            <.tile
              label="Blocked"
              value={if @report["blocked"], do: "yes", else: "no"}
              tone={if @report["blocked"], do: "danger", else: "neutral"}
            />
            <.tile label="Requirements" value={length(@report["requirements"] || [])} />
            <.tile label="Report version" value={@report["report_version"]} />
          </div>

          <.empty
            :if={(@report["requirements"] || []) == []}
            message="No active card applies to that skill at that scope, so there is nothing to satisfy — and nothing that authorizes the skill either."
          />

          <table :if={(@report["requirements"] || []) != []} class="grid">
            <thead>
              <tr>
                <th>Requirement</th>
                <th>Level</th>
                <th>Status</th>
                <th>Satisfied by</th>
                <th>Prompt if missing</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={requirement <- @report["requirements"]}>
                <td>
                  <strong>{requirement["key"]}</strong>
                  <p :if={requirement["description"]} class="muted">{requirement["description"]}</p>
                </td>
                <td><.badge family="level" value={requirement["level"]} /></td>
                <td><.badge family="state" value={requirement["status"]} /></td>
                <td>
                  <.id_chip
                    :for={id <- requirement["satisfied_by"] || []}
                    value={id}
                    navigate={~p"/console/knowledge/#{id}"}
                  />
                  <span :if={(requirement["satisfied_by"] || []) == []} class="muted">—</span>
                </td>
                <td class="muted">{requirement["prompt"] || "—"}</td>
              </tr>
            </tbody>
          </table>

          <p :if={(@report["blockers"] || []) != []} class="hint">
            A blocker stops the skill. Answering it is not a shortcut: the answer must arrive
            as an ordinary observation and pass the gates before this check changes.
          </p>
        </div>
      </.panel>

      <.panel
        title="Card library"
        description="Every published version, newest first within each skill. Exactly one version per scope and skill key is active; the rest are history."
      >
        <p :if={Access.can?(@current_actor, :curate)} class="hint">
          Publishing a new version is a curator act and happens on the
          <a href={~p"/governance"}>curator queue page</a>.
        </p>

        <.empty :if={@skills.cards == []} message="No skill card has been authored." />

        <article :for={card <- @skills.cards} class="record">
          <header class="record-head">
            <h3>{card.skill_key}</h3>
            <div class="badge-row">
              <span class="badge">version {card.version}</span>
              <span class="badge">{card.requirement_schema_version}</span>
              <.badge family="state" value={if card.active, do: "active", else: "retired"} />
            </div>
          </header>
          <p class="muted">{card.scope_path || "(unreadable scope)"}</p>
          <p :if={card.description}>{card.description}</p>
          <pre class="code">{Jason.encode!(card.requirements, pretty: true)}</pre>
        </article>
      </.panel>
    </.shell>
    """
  end
end
