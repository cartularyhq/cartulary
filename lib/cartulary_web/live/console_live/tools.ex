# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.ConsoleLive.Tools do
  @moduledoc """
  Browser workbench for the complete MCP tool inventory at `/console/tools`.

  Every form invokes the same non-persisted Ash action published through
  `Cartulary.Governance`, so argument casting, Account derivation, scope policy,
  inline validation attachment, and response shape stay aligned with MCP. The
  browser session supplies the actor; no form may select an Account or another
  calling peer.

  The page groups tools by intent and carries one shared session and scope, but
  the submitted arguments are still exactly the action's declared arguments: a
  card may override the shared context, and nothing else about the call is
  derived from the grouping. Summaries are a reading aid over the same payload,
  never a substitute for it, so the exact returned value stays on the page.

  Results are rendered only into the signed-in LiveView. They must never be
  copied into logs, telemetry, audit metadata, or job arguments.
  """

  use CartularyWeb, :live_view

  import CartularyWeb.ConsoleComponents

  alias Cartulary.Governance.McpTools
  alias CartularyWeb.Console.Access
  alias CartularyWeb.Console.Loader

  # Kept as a list rather than a map so declaration order is the render order
  # within a group, and so the human title, submit label, and consequence text
  # live next to the action they describe.
  @tools [
    %{
      key: "ask",
      action: :ask,
      group: :retrieve,
      title: "Ask memory",
      submit: "Ask memory",
      effect: "Governed read",
      write?: false,
      description:
        "Answer a question from governed statements, with citations and an explicit abstention when the evidence is insufficient.",
      consequence: "Reads only statements you may already see. Nothing is written."
    },
    %{
      key: "search",
      action: :search,
      group: :retrieve,
      title: "Search memory",
      submit: "Search memory",
      effect: "Governed read",
      write?: false,
      description:
        "Rank governed memory and report which retrieval strategies contributed, missed, or timed out.",
      consequence: "Reads only statements you may already see. Nothing is written."
    },
    %{
      key: "get_context",
      action: :get_context,
      group: :retrieve,
      title: "Load context",
      submit: "Load context",
      effect: "Governed read",
      write?: false,
      description:
        "Assemble reasoning-free context from projections, falling back to fast retrieval on a cache miss.",
      consequence: "Reads cached projections. No model runs and nothing is written."
    },
    %{
      key: "query_knowledge",
      action: :query_knowledge,
      group: :retrieve,
      title: "Browse knowledge",
      submit: "Browse knowledge",
      effect: "Governed read",
      write?: false,
      description:
        "List governed statements by lifecycle state. This is structured enumeration, not ranked retrieval.",
      consequence: "Reads only statements you may already see. Nothing is written."
    },
    %{
      key: "ingest",
      action: :ingest,
      group: :operate,
      title: "Save observation",
      submit: "Save observation",
      effect: "Writes an observation",
      write?: true,
      description:
        "Submit one raw observation. It is persisted and queued; only the pipeline may produce knowledge from it.",
      consequence:
        "This stores a raw observation in the chosen scope and queues extraction. It cannot be unsent."
    },
    %{
      key: "resolve_validation",
      action: :resolve_validation,
      group: :operate,
      title: "Resolve validation",
      submit: "Resolve validation",
      effect: "May change validation state",
      write?: true,
      description:
        "Answer one pending question addressed to you. Transcript evidence still decides whether the channel counts as verified.",
      consequence:
        "This records your verdict against a pending question and may change a statement's validation state."
    },
    %{
      key: "set_ask_preference",
      action: :set_ask_preference,
      group: :operate,
      title: "Update question limits",
      submit: "Update question limits",
      effect: "Tightens your preferences",
      write?: true,
      description:
        "Reduce your inline-question limits or pause questions. This tool can tighten settings, never loosen them.",
      consequence:
        "This lowers your own inline-question limits or extends your pause. It cannot raise them again here."
    },
    %{
      key: "check_readiness",
      action: :check_readiness,
      group: :evaluate,
      title: "Check readiness",
      submit: "Check readiness",
      effect: "Governed read",
      write?: false,
      description:
        "Evaluate inherited skill requirements against authorized, usable knowledge without running a model.",
      consequence: "Evaluates requirements only. No model runs and nothing is written."
    }
  ]

  @groups [
    %{
      key: :retrieve,
      title: "Retrieve",
      description: "Read what memory already holds. These calls write nothing."
    },
    %{
      key: :operate,
      title: "Operate",
      description:
        "These calls change durable state under your own identity. Read the consequence before you submit."
    },
    %{
      key: :evaluate,
      title: "Evaluate",
      description: "Check whether memory is good enough to run a skill."
    }
  ]

  # Ordered so a run's context summary reads like the form, and so a parameter
  # that is not a declared argument of any tool never reaches the summary.
  @context_labels [
    {"session_id", "Session"},
    {"scope_path", "Scope"},
    {"role", "Role"},
    {"content", "Content"},
    {"query", "Query"},
    {"question", "Question"},
    {"state", "State"},
    {"skill", "Skill"},
    {"profile", "Retrieval profile"},
    {"limit", "Limit"},
    {"_id", "Validation id"},
    {"verdict", "Verdict"},
    {"shown_text", "Shown text"},
    {"correction_text", "Correction text"},
    {"max_per_session", "Max per session"},
    {"max_per_day", "Max per day"},
    {"pause_for_hours", "Pause for hours"}
  ]

  # Enough to compare a run with the one before it without turning the page
  # into a transcript. Older runs are dropped, never persisted.
  @history_limit 5

  @doc """
  Loads authorized scope choices and seeds the shared run context.
  """
  @impl true
  def mount(_params, _session, socket) do
    scopes = Loader.skills(socket.assigns.current_actor).scopes

    {:ok,
     socket
     |> assign(:scopes, scopes)
     |> assign(:session_id, "console-#{Ecto.UUID.generate()}")
     |> assign(:scope_path, default_scope_path(scopes))
     |> assign(:runs, [])
     |> assign(:run_count, 0)}
  end

  @doc """
  Handles the page's four events.

  `"context"` stores the shared session and scope so every card starts from one
  context, and `"new-session"` replaces the session id. `"run"` invokes one
  allowlisted tool through the same Ash action used by MCP: empty optional
  fields are omitted so action defaults remain authoritative, and a failure
  returns one opaque browser message without logging or reflecting action
  internals into the page. Earlier runs survive a failure so the context that
  produced them is not lost, until `"clear-runs"` discards them.
  """
  @impl true
  def handle_event("context", params, socket) do
    {:noreply,
     socket
     |> assign(:session_id, Map.get(params, "session_id", socket.assigns.session_id))
     |> assign(:scope_path, Map.get(params, "scope_path", socket.assigns.scope_path))}
  end

  def handle_event("new-session", _params, socket) do
    {:noreply, assign(socket, :session_id, "console-#{Ecto.UUID.generate()}")}
  end

  def handle_event("run", %{"tool" => key} = params, socket) do
    with {:ok, tool} <- fetch_tool(key),
         input <- action_input(tool.action, params),
         {:ok, result} <- run_action(input, socket.assigns.current_actor) do
      count = socket.assigns.run_count + 1
      result = browser_result(tool, params, result, socket.assigns.current_actor)

      run = %{
        number: count,
        tool: tool,
        context: context_rows(params),
        summary: summary_rows(tool, result),
        json: Jason.encode!(result, pretty: true),
        diagnostic_trace: value(result, "diagnostic_trace")
      }

      {:noreply,
       socket
       |> assign(:run_count, count)
       |> assign(:runs, Enum.take([run | socket.assigns.runs], @history_limit))
       |> clear_flash()}
    else
      _error ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Tool call failed. Check the fields and your access, then try again."
         )}
    end
  end

  def handle_event("clear-runs", _params, socket) do
    {:noreply, assign(socket, :runs, [])}
  end

  @doc """
  Renders the shared context, the grouped tool cards, and recent run results.
  """
  @impl true
  def render(assigns) do
    assigns = assign(assigns, :groups, @groups)

    ~H"""
    <.shell actor={@current_actor} active={:tools} title="Tool workbench" flash={@flash}>
      <:subtitle>
        Run everything an agent can reach at <code>/mcp</code>, under your signed-in identity.
        These are the real operations against your own memory, not sample data.
      </:subtitle>

      <%!--
        One datalist serves every scope control on the page, so it has to sit
        outside all of the forms. Options are the paths the viewer may already
        read; typing an unauthorized path fails downstream like any other bad
        argument.
      --%>
      <datalist id="scope-options">
        <option :for={scope <- @scopes} value={scope.path}></option>
      </datalist>

      <.panel
        title="Run context"
        description="Set the session and scope once. Any card can override them for a single run."
      >
        <form id="run-context" class="context-bar" phx-change="context" phx-submit="context">
          <.field label="Session id" help="Reuse one id to keep calls part of the same interaction.">
            <input name="session_id" value={@session_id} autocomplete="off" spellcheck="false" />
          </.field>
          <.field label="Scope" help={scope_help(@scopes, @scope_path)}>
            <input
              name="scope_path"
              value={@scope_path}
              list="scope-options"
              autocomplete="off"
              spellcheck="false"
            />
          </.field>
        </form>
        <div class="button-row">
          <button type="button" class="ghost" phx-click="new-session">Start a new session id</button>
          <span class="hint">{length(@scopes)} scopes you can reach</span>
        </div>
      </.panel>

      <.panel
        :if={@runs != []}
        title={"#{hd(@runs).tool.title} · run #{hd(@runs).number}"}
        description="The payload is the exact value returned by the underlying action. Content stays in this browser session."
      >
        <.run_body run={hd(@runs)} open />
        <div class="button-row">
          <button type="button" class="ghost" phx-click="clear-runs">Clear results</button>
        </div>
      </.panel>

      <.panel :if={length(@runs) > 1} title="Earlier runs" description="Kept only in this page.">
        <details :for={run <- tl(@runs)} class="earlier-run">
          <summary>
            <span class="run-title">{run.tool.title}</span>
            <span class="muted">run {run.number}</span>
          </summary>
          <.run_body run={run} />
        </details>
      </.panel>

      <section :for={group <- @groups} class="tool-group">
        <header class="group-head">
          <h2>{group.title}</h2>
          <p>{group.description}</p>
        </header>

        <div class="tool-grid">
          <.tool_panel :for={tool <- tools_in(group.key)} tool={tool}>
            <.tool_fields
              tool={tool}
              session_id={@session_id}
              scope_path={@scope_path}
              diagnostics?={Access.can?(@current_actor, :administer)}
            />
          </.tool_panel>
        </div>
      </section>
    </.shell>
    """
  end

  attr :tool, :map, required: true
  slot :inner_block, required: true

  defp tool_panel(assigns) do
    ~H"""
    <section
      class={["panel", "tool-panel", @tool.write? && "is-write"]}
      id={"tool-#{@tool.key}"}
      aria-labelledby={"tool-#{@tool.key}-title"}
    >
      <header class="tool-head">
        <div>
          <h3 id={"tool-#{@tool.key}-title"}>{@tool.title}</h3>
          <p>{@tool.description}</p>
        </div>
        <span class={["badge", @tool.write? && "state-pending"]}>
          <span aria-hidden="true">{if @tool.write?, do: "▲", else: "▾"}</span> {@tool.effect}
        </span>
      </header>

      <form phx-submit="run" class="tool-form">
        <input type="hidden" name="tool" value={@tool.key} />
        {render_slot(@inner_block)}

        <%!--
          The acknowledgement is a browser-side affordance only. The operation
          layer re-authorizes every write, so a hand-crafted event that omits
          it is refused there rather than here.
        --%>
        <label :if={@tool.write?} class="full ack">
          <input type="checkbox" name="_ack" required />
          <span>{@tool.consequence}</span>
        </label>
        <p :if={!@tool.write?} class="full consequence">{@tool.consequence}</p>

        <div class="full button-row">
          <button class="primary" phx-disable-with="Running…">{@tool.submit}</button>
          <span class="technical">Action <code>{@tool.key}</code></span>
        </div>
      </form>
    </section>
    """
  end

  attr :tool, :map, required: true
  attr :session_id, :string, required: true
  attr :scope_path, :string, required: true
  attr :diagnostics?, :boolean, default: false

  defp tool_fields(%{tool: %{key: "ask"}} = assigns) do
    ~H"""
    <.context_override session_id={@session_id} scope_path={@scope_path} />
    <.field label="Question" class="full">
      <textarea name="question" rows="3" required placeholder="What do we know?"></textarea>
    </.field>
    <.profile selected="thorough" />
    <.diagnostic_trace_request :if={@diagnostics?} />
    """
  end

  defp tool_fields(%{tool: %{key: "search"}} = assigns) do
    ~H"""
    <.context_override session_id={@session_id} scope_path={@scope_path} />
    <.field label="Query" class="full">
      <input name="query" required autocomplete="off" placeholder="What should memory find?" />
    </.field>
    <.profile selected="balanced" />
    <.limit />
    <.diagnostic_trace_request :if={@diagnostics?} />
    """
  end

  defp tool_fields(%{tool: %{key: "get_context"}} = assigns) do
    ~H"""
    <.context_override session_id={@session_id} scope_path={@scope_path} />
    <.field label="Query" optional class="full" help="Narrows the context to what this turn is about.">
      <input name="query" autocomplete="off" placeholder="What this turn is about" />
    </.field>
    <.limit />
    """
  end

  defp tool_fields(%{tool: %{key: "query_knowledge"}} = assigns) do
    ~H"""
    <.context_override session_id={@session_id} scope_path={@scope_path} />
    <.field
      label="Lifecycle state"
      optional
      help="Left empty, this lists active statements plus your own provisional ones."
    >
      <select name="state">
        <option value="">active plus your provisional statements</option>
        <option
          :for={
            state <-
              ~w(active provisional proposed held needs_revalidation expired superseded rejected contested redacted retracted)
          }
          value={state}
        >
          {state}
        </option>
      </select>
    </.field>
    <.limit />
    """
  end

  defp tool_fields(%{tool: %{key: "ingest"}} = assigns) do
    ~H"""
    <.context_override session_id={@session_id} scope_path={@scope_path} />
    <.field label="Role" help="Who the observation came from. Defaults to user.">
      <select name="role">
        <option :for={role <- ~w(user assistant system tool)} value={role}>{role}</option>
      </select>
    </.field>
    <.field label="Content" class="full">
      <textarea name="content" rows="5" required placeholder="The observation to remember"></textarea>
    </.field>
    """
  end

  defp tool_fields(%{tool: %{key: "check_readiness"}} = assigns) do
    ~H"""
    <.context_override
      session_id={@session_id}
      scope_path={@scope_path}
      optional_session
    />
    <.field label="Skill key" class="full" help="The skill card key, for example write-copy.">
      <input name="skill" required autocomplete="off" placeholder="write-copy" />
    </.field>
    """
  end

  defp tool_fields(%{tool: %{key: "resolve_validation"}} = assigns) do
    ~H"""
    <.field
      label="Validation id"
      class="full"
      help="The id returned as pending_validation on an earlier read."
    >
      <input name="_id" required autocomplete="off" placeholder="UUID from pending_validation" />
    </.field>
    <.field label="Verdict">
      <select name="verdict" required>
        <option :for={verdict <- ~w(confirm reject unsure skip)} value={verdict}>{verdict}</option>
      </select>
    </.field>
    <.field
      label="Shown text"
      optional
      class="full"
      help="What you were shown. Only its hash is stored, to check the wording was not altered."
    >
      <textarea name="shown_text" rows="3" placeholder="Frozen statement shown to you"></textarea>
    </.field>
    <.field
      label="Correction text"
      optional
      class="full"
      help="Evidence only. A correction becomes knowledge only when you save it as an observation."
    >
      <textarea name="correction_text" rows="3" placeholder="Evidence only; ingest a correction separately">
      </textarea>
    </.field>
    """
  end

  defp tool_fields(%{tool: %{key: "set_ask_preference"}} = assigns) do
    ~H"""
    <.field label="Max per session" optional help="Zero means never ask during a session.">
      <input name="max_per_session" type="number" min="0" step="1" />
    </.field>
    <.field label="Max per day" optional help="Zero means never ask at all.">
      <input name="max_per_day" type="number" min="0" step="1" />
    </.field>
    <.field label="Pause for hours" optional class="full" help="Stored as an absolute resume time.">
      <input name="pause_for_hours" type="number" min="0" step="1" />
    </.field>
    """
  end

  attr :session_id, :string, required: true
  attr :scope_path, :string, required: true
  attr :optional_session, :boolean, default: false

  defp context_override(assigns) do
    ~H"""
    <%!--
      Collapsed by default: the shared bar above already answers "which session
      and scope is this?", and repeating two controls on every card is what made
      the page feel like a form dump. The fields stay in the form so a single
      card can still deviate without changing the page-wide context.
    --%>
    <details class="full context-override">
      <summary>
        <span class="muted">Context</span>
        <code>{@session_id}</code>
        <code>{@scope_path}</code>
      </summary>
      <div class="override-fields">
        <.field label="Session id" optional={@optional_session}>
          <input
            name="session_id"
            value={@session_id}
            required={!@optional_session}
            autocomplete="off"
            spellcheck="false"
          />
        </.field>
        <.field label="Scope">
          <input
            name="scope_path"
            value={@scope_path}
            list="scope-options"
            required
            autocomplete="off"
            spellcheck="false"
          />
        </.field>
      </div>
    </details>
    """
  end

  attr :selected, :string, required: true

  defp profile(assigns) do
    ~H"""
    <.field label="Retrieval profile" help={"Defaults to #{@selected}: more work, slower answer."}>
      <select name="profile">
        <option :for={profile <- ~w(fast balanced thorough)} value={profile} selected={profile == @selected}>
          {profile}{if profile == @selected, do: " (default)"}
        </option>
      </select>
    </.field>
    """
  end

  defp limit(assigns) do
    ~H"""
    <.field label="Limit" optional help="Rows to return. Defaults to 12.">
      <input name="limit" type="number" min="1" step="1" placeholder="12" />
    </.field>
    """
  end

  defp diagnostic_trace_request(assigns) do
    ~H"""
    <label class="full diagnostic-trace-request">
      <input name="diagnostic_trace" type="checkbox" value="true" />
      <span>Show rank diagnostics for this run</span>
      <span class="field-help">Admin only. Strategy scores use different scales; compare ranks, not scores.</span>
    </label>
    """
  end

  attr :label, :string, required: true
  attr :help, :string, default: nil
  attr :optional, :boolean, default: false
  attr :class, :string, default: nil
  slot :inner_block, required: true

  # The label wraps its control, so the control needs no id to be named, and the
  # help text stays inside the label so assistive technology reads the reason a
  # choice matters rather than only the field name.
  defp field(assigns) do
    ~H"""
    <div class={["field", @class]}>
      <label>
        <span class="field-label">
          {@label}<span :if={@optional} class="optional">optional</span>
        </span>
        {render_slot(@inner_block)}
        <span :if={@help} class="field-help">{@help}</span>
      </label>
    </div>
    """
  end

  attr :run, :map, required: true
  attr :open, :boolean, default: false

  defp run_body(assigns) do
    ~H"""
    <p class="technical">Result · {@run.tool.key}</p>

    <dl :if={@run.summary != []} class="run-summary">
      <div :for={{label, value} <- @run.summary} class="run-row">
        <dt>{label}</dt>
        <dd>{value}</dd>
      </div>
    </dl>

    <.diagnostic_trace :if={@run.diagnostic_trace} trace={@run.diagnostic_trace} />

    <details :if={@run.context != []} class="run-context">
      <summary>What was submitted</summary>
      <dl class="run-summary">
        <div :for={{label, value} <- @run.context} class="run-row">
          <dt>{label}</dt>
          <dd>{value}</dd>
        </div>
      </dl>
    </details>

    <details open={@open} class="run-raw">
      <summary>Raw payload</summary>
      <pre id={"tool-result-#{@run.number}"} class="code tool-result">{@run.json}</pre>
    </details>
    """
  end

  attr :trace, :map, required: true

  defp diagnostic_trace(assigns) do
    ~H"""
    <details class="retrieval-trace">
      <summary>Retrieval diagnostics</summary>
      <p class="hint">Ranks are comparable across strategies. Scores are local to each strategy.</p>
      <div class="table-scroll">
        <table class="grid compact">
          <thead>
            <tr><th>Candidate</th><th>Fused</th><th>Final</th><th>Rerank</th><th>Strategy details</th></tr>
          </thead>
          <tbody>
            <tr :for={candidate <- @trace["candidates"]}>
              <td><code>{candidate["id"]}</code></td>
              <td>{candidate["fused_rank"]}</td>
              <td>{candidate["final_rank"]}</td>
              <td>{candidate["rerank_status"]}</td>
              <td>
                <details>
                  <summary>{length(candidate["strategies"])} strategies</summary>
                  <table class="grid compact">
                    <thead><tr><th>Strategy</th><th>Local rank</th><th>Local score</th><th>Fusion contribution</th></tr></thead>
                    <tbody>
                      <tr :for={strategy <- candidate["strategies"]}>
                        <td>{strategy["strategy"]}</td>
                        <td>{strategy["local_rank"]}</td>
                        <td>{number(strategy["local_score"])}</td>
                        <td>{number(strategy["fusion_contribution"])}</td>
                      </tr>
                    </tbody>
                  </table>
                </details>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </details>
    """
  end

  defp tools_in(group), do: Enum.filter(@tools, &(&1.group == group))

  defp fetch_tool(key) do
    case Enum.find(@tools, &(&1.key == key)) do
      nil -> :error
      tool -> {:ok, tool}
    end
  end

  defp default_scope_path([scope | _rest]), do: scope.path
  defp default_scope_path(_scopes), do: ""

  # Says what the chosen scope is without listing the tree again, and names an
  # unauthorized path plainly so a typo does not look like an empty account.
  defp scope_help(scopes, path) do
    cond do
      path in ["", nil] ->
        "Choose one of your authorized scopes."

      Enum.any?(scopes, &(&1.path == path)) ->
        depth = path |> String.split("/", trim: true) |> length()
        "Depth #{depth}. Knowledge inherits down from here; the nearest scope wins."

      true ->
        "Not a scope you can read. Calls using it will be refused."
    end
  end

  defp context_rows(params) do
    for {parameter, label} <- @context_labels,
        value = Map.get(params, parameter),
        value not in [nil, ""],
        do: {label, truncate(to_string(value), 160)}
  end

  # A reading aid over the payload below it, not a second source of truth: every
  # row is copied from a key the action actually returned, and a key the action
  # omitted produces no row rather than a guessed default.
  defp summary_rows(%{key: "ingest"}, result) do
    rows([{"Status", value(result, "status")}, {"Message id", value(result, "message_id")}])
  end

  defp summary_rows(%{key: "get_context"}, result) do
    rows([
      {"Knowledge items", count(result, "knowledge")},
      {"Scope cards", count(result, "scope_cards")},
      {"Projection cache hit", value(result, "projection_cache_hit")},
      {"Fast fallback", value(result, "fast_fallback")},
      {"Inline question", pending(result)}
    ])
  end

  defp summary_rows(%{key: "search"}, result) do
    rows([
      {"Candidates", count(result, "candidates")},
      {"Retrieval profile", value(result, "profile")},
      {"Strategies contributed", count(result, "contributed_strategies")},
      {"Strategies empty", count(result, "empty_strategies")},
      {"Latency", latency(result)},
      {"Index health", retrieval_health(result)},
      {"Inline question", pending(result)}
    ])
  end

  defp summary_rows(%{key: "ask"}, result) do
    rows([
      {"Answer", truncate(to_string(value(result, "answer") || ""), 600)},
      {"Abstained", value(result, "abstained")},
      {"Citations", count(result, "citations")},
      {"Candidates", count(result, "candidates")},
      {"Index health", retrieval_health(result)},
      {"Inline question", pending(result)}
    ])
  end

  defp summary_rows(%{key: "query_knowledge"}, result) do
    rows([{"Statements", count(result, "data")}, {"Inline question", pending(result)}])
  end

  defp summary_rows(%{key: "check_readiness"}, result) do
    rows([
      {"Ready", value(result, "ready")},
      {"Skill", value(result, "skill")},
      {"Scope", value(result, "scope_path")},
      {"Requirements", count(result, "requirements")},
      {"Blockers", count(result, "blockers")},
      {"Warnings", count(result, "warnings")}
    ])
  end

  defp summary_rows(%{key: "resolve_validation"}, result) do
    rows([
      {"Verdict", value(result, "verdict")},
      {"Verified channel", value(result, "verified")},
      {"Effect", value(result, "effect")}
    ])
  end

  defp summary_rows(%{key: "set_ask_preference"}, result) do
    rows([
      {"Max per session", value(result, "max_per_session")},
      {"Max per day", value(result, "max_per_day")},
      {"Paused until", value(result, "paused_until")}
    ])
  end

  defp rows(pairs) do
    for {label, value} <- pairs, not is_nil(value), do: {label, display(value)}
  end

  # Read actions return string keys through the memory facade; the two
  # governance actions build their own maps with atom keys.
  defp value(result, key) when is_map(result) do
    case Map.fetch(result, key) do
      {:ok, value} -> value
      :error -> Map.get(result, String.to_existing_atom(key))
    end
  rescue
    ArgumentError -> nil
  end

  defp value(_result, _key), do: nil

  defp count(result, key) do
    case value(result, key) do
      list when is_list(list) -> length(list)
      _other -> nil
    end
  end

  # Fusion contributions land around 1/60, so four places is the point where the
  # column still separates two adjacent ranks without printing float noise.
  defp number(value) when is_number(value), do: Float.round(value * 1.0, 4)

  defp pending(result) do
    if value(result, "pending_validation"), do: "one question attached"
  end

  # A degraded index answers with the same shape as a healthy one, so the state
  # belongs in the summary rather than only in the payload below it.
  defp retrieval_health(result) do
    case value(result, "retrieval_health") do
      %{state: state, next_action: nil} -> to_string(state)
      %{state: state, next_action: action} -> "#{state} — #{action}"
      _other -> nil
    end
  end

  defp latency(result) do
    case value(result, "latency_ms") do
      milliseconds when is_number(milliseconds) -> "#{milliseconds} ms"
      _other -> nil
    end
  end

  defp display(true), do: "yes"
  defp display(false), do: "no"
  defp display(value) when is_binary(value), do: value
  defp display(value), do: to_string(value)

  # A non-public argument inside the public parameter map is rejected as
  # `NoSuchInput`, which fails the whole call rather than the one field, so the
  # browser-only arguments are applied separately. Both still go through the
  # action's own casting and validation.
  defp action_input(action, params) do
    {public, private} =
      McpTools
      |> Ash.Resource.Info.action(action)
      |> Map.fetch!(:arguments)
      |> Enum.reduce({%{}, []}, fn argument, {public, private} = unchanged ->
        parameter = if argument.name == :id, do: "_id", else: to_string(argument.name)

        case Map.get(params, parameter) do
          value when value in [nil, ""] ->
            unchanged

          value ->
            if argument.public? do
              {Map.put(public, argument.name, value), private}
            else
              {public, [{argument.name, value} | private]}
            end
        end
      end)

    input = Ash.ActionInput.for_action(McpTools, action, public)

    Enum.reduce(private, input, fn {name, value}, input ->
      Ash.ActionInput.set_private_argument(input, name, value)
    end)
  end

  # Browser-only addition, not part of the MCP or HTTP contract. The atom key is
  # what keeps it distinguishable from the action's own string-keyed payload.
  defp browser_result(%{key: key}, params, result, actor) when key in ["search", "ask"] do
    Map.put(
      result,
      :retrieval_health,
      Loader.retrieval_health(
        actor,
        Map.get(params, "scope_path"),
        Map.get(params, "query") || Map.get(params, "question")
      )
    )
  end

  defp browser_result(_tool, _params, result, _actor), do: result

  # Ash normally returns action failures as error tuples. These classes may be
  # raised by a downstream resource instead; keep the browser response equally
  # opaque in both cases so identifiers cannot be probed through error detail.
  defp run_action(input, actor) do
    Ash.run_action(input, actor: actor)
  rescue
    _error in [
      Ash.Error.Forbidden,
      Ash.Error.Invalid,
      Ash.Error.Query.NotFound,
      Ash.Error.Unknown
    ] ->
      {:error, :tool_failed}
  end
end
