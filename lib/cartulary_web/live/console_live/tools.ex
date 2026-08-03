# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.ConsoleLive.Tools do
  @moduledoc """
  Browser workbench for the complete MCP tool inventory at `/console/tools`.

  Every form invokes the same non-persisted Ash action published through
  `Cartulary.Governance`, so argument casting, Account derivation, scope policy,
  inline validation attachment, and response shape stay aligned with MCP. The
  browser session supplies the actor; no form may select an Account or another
  calling peer.

  Results are rendered only into the signed-in LiveView. They must never be
  copied into logs, telemetry, audit metadata, or job arguments.
  """

  use CartularyWeb, :live_view

  import CartularyWeb.ConsoleComponents

  alias Cartulary.Governance.McpTools
  alias CartularyWeb.Console.Loader

  @tool_actions %{
    "ingest" => :ingest,
    "get_context" => :get_context,
    "search" => :search,
    "ask" => :ask,
    "query_knowledge" => :query_knowledge,
    "check_readiness" => :check_readiness,
    "resolve_validation" => :resolve_validation,
    "set_ask_preference" => :set_ask_preference
  }

  @doc """
  Loads authorized scope choices and creates a per-mount session id suggestion.
  """
  @impl true
  def mount(_params, _session, socket) do
    scopes = Loader.skills(socket.assigns.current_actor).scopes

    {:ok,
     socket
     |> assign(:scopes, scopes)
     |> assign(:session_id, "console-#{Ecto.UUID.generate()}")
     |> assign(:result, nil)}
  end

  @doc """
  Runs one allowlisted tool through the same Ash action used by MCP.

  Empty optional fields are omitted so action defaults remain authoritative.
  Failures return one opaque browser message; action internals and content are
  not logged or reflected into the page.
  """
  @impl true
  def handle_event("run", %{"tool" => tool} = params, socket) do
    with {:ok, action} <- Map.fetch(@tool_actions, tool),
         input <- Ash.ActionInput.for_action(McpTools, action, action_arguments(action, params)),
         {:ok, result} <- run_action(input, socket.assigns.current_actor) do
      {:noreply,
       socket
       |> assign(:result, %{tool: tool, json: Jason.encode!(result, pretty: true)})
       |> clear_flash()}
    else
      _error ->
        {:noreply,
         socket
         |> assign(:result, nil)
         |> put_flash(
           :error,
           "Tool call failed. Check the fields and your access, then try again."
         )}
    end
  end

  def handle_event("clear-result", _params, socket) do
    {:noreply, assign(socket, :result, nil)}
  end

  @doc """
  Renders forms for all eight tools and the latest exact result payload.
  """
  @impl true
  def render(assigns) do
    ~H"""
    <.shell actor={@current_actor} active={:tools} title="Tool workbench" flash={@flash}>
      <:subtitle>
        Run every tool exposed at <code>/mcp</code> with your signed-in identity and inspect
        the returned shape. These are the real operations, not sample data.
      </:subtitle>

      <.panel
        :if={@result}
        title={"Result · #{@result.tool}"}
        description="The payload is the same value returned by the underlying MCP action. Content stays in this browser session."
      >
        <div class="result-head">
          <span class="badge state-active">completed</span>
          <button type="button" class="ghost" phx-click="clear-result">Clear result</button>
        </div>
        <pre id="tool-result" class="code tool-result">{@result.json}</pre>
      </.panel>

      <div class="tool-grid">
        <.tool_panel
          name="ingest"
          description="Submit one raw observation. It is persisted and queued; only the pipeline may produce knowledge."
          effect="Writes an observation"
          tone="warn"
        >
          <.session_scope session_id={@session_id} scopes={@scopes} />
          <label>
            Role
            <select name="role">
              <option value="user">user</option>
              <option value="assistant">assistant</option>
              <option value="system">system</option>
              <option value="tool">tool</option>
            </select>
          </label>
          <label class="full">
            Content
            <textarea name="content" rows="5" required placeholder="The observation to remember"></textarea>
          </label>
        </.tool_panel>

        <.tool_panel
          name="get_context"
          description="Assemble reasoning-free context from projections, with a fast retrieval fallback on a cache miss."
        >
          <.session_scope session_id={@session_id} scopes={@scopes} />
          <label class="full">
            Query <span class="optional">optional</span>
            <input name="query" autocomplete="off" placeholder="What this turn is about" />
          </label>
          <.limit />
        </.tool_panel>

        <.tool_panel
          name="search"
          description="Rank governed memory and report the retrieval strategies that contributed, missed, or timed out."
        >
          <.session_scope session_id={@session_id} scopes={@scopes} />
          <label class="full">
            Query
            <input name="query" required autocomplete="off" placeholder="What should memory find?" />
          </label>
          <.profile selected="balanced" />
          <.limit />
        </.tool_panel>

        <.tool_panel
          name="ask"
          description="Answer from governed statements with citations and explicit abstention when the evidence is insufficient."
        >
          <.session_scope session_id={@session_id} scopes={@scopes} />
          <label class="full">
            Question
            <textarea name="question" rows="3" required placeholder="What do we know?"></textarea>
          </label>
          <.profile selected="thorough" />
        </.tool_panel>

        <.tool_panel
          name="query_knowledge"
          description="List governed statements by lifecycle state. This is structured enumeration, not ranked retrieval."
        >
          <.session_scope session_id={@session_id} scopes={@scopes} />
          <label>
            State <span class="optional">optional</span>
            <select name="state">
              <option value="">active plus your provisional statements</option>
              <option :for={state <- ~w(active provisional proposed held needs_revalidation expired superseded rejected contested redacted retracted)} value={state}>
                {state}
              </option>
            </select>
          </label>
          <.limit />
        </.tool_panel>

        <.tool_panel
          name="check_readiness"
          description="Evaluate inherited skill requirements against authorized, usable knowledge without running a model."
        >
          <.session_scope session_id={@session_id} scopes={@scopes} optional_session />
          <label class="full">
            Skill key
            <input name="skill" required autocomplete="off" placeholder="write-copy" />
          </label>
        </.tool_panel>

        <.tool_panel
          name="resolve_validation"
          description="Answer one pending question addressed to you. Transcript evidence still decides whether the channel is verified."
          effect="May change validation state"
          tone="warn"
        >
          <label class="full">
            Validation id
            <input name="_id" required autocomplete="off" placeholder="UUID from pending_validation" />
          </label>
          <label>
            Verdict
            <select name="verdict" required>
              <option value="confirm">confirm</option>
              <option value="reject">reject</option>
              <option value="unsure">unsure</option>
              <option value="skip">skip</option>
            </select>
          </label>
          <label class="full">
            Shown text <span class="optional">optional</span>
            <textarea name="shown_text" rows="3" placeholder="Frozen statement shown to you"></textarea>
          </label>
          <label class="full">
            Correction text <span class="optional">optional</span>
            <textarea name="correction_text" rows="3" placeholder="Evidence only; ingest a correction separately"></textarea>
          </label>
        </.tool_panel>

        <.tool_panel
          name="set_ask_preference"
          description="Reduce your inline-question limits or pause questions. This tool can tighten settings, never loosen them."
          effect="Tightens your preferences"
          tone="warn"
        >
          <label>
            Max per session <span class="optional">optional</span>
            <input name="max_per_session" type="number" min="0" step="1" />
          </label>
          <label>
            Max per day <span class="optional">optional</span>
            <input name="max_per_day" type="number" min="0" step="1" />
          </label>
          <label class="full">
            Pause for hours <span class="optional">optional</span>
            <input name="pause_for_hours" type="number" min="0" step="1" />
          </label>
        </.tool_panel>
      </div>
    </.shell>
    """
  end

  attr :name, :string, required: true
  attr :description, :string, required: true
  attr :effect, :string, default: "Governed read"
  attr :tone, :string, default: "neutral"
  slot :inner_block, required: true

  defp tool_panel(assigns) do
    ~H"""
    <section class="panel tool-panel" id={"tool-#{@name}"}>
      <header class="tool-head">
        <div>
          <h2><code>{@name}</code></h2>
          <p>{@description}</p>
        </div>
        <span class={["badge", @tone == "warn" && "state-pending"]}>{@effect}</span>
      </header>
      <form phx-submit="run" class="tool-form">
        <input type="hidden" name="tool" value={@name} />
        {render_slot(@inner_block)}
        <div class="full button-row">
          <button class="primary">Run {@name}</button>
        </div>
      </form>
    </section>
    """
  end

  attr :session_id, :string, required: true
  attr :scopes, :list, required: true
  attr :optional_session, :boolean, default: false

  defp session_scope(assigns) do
    ~H"""
    <label>
      Session id <span :if={@optional_session} class="optional">optional</span>
      <input name="session_id" value={@session_id} required={!@optional_session} autocomplete="off" />
    </label>
    <label>
      Scope
      <select name="scope_path" required>
        <option :for={scope <- @scopes} value={scope.path}>{scope.path}</option>
      </select>
    </label>
    """
  end

  attr :selected, :string, required: true

  defp profile(assigns) do
    ~H"""
    <label>
      Retrieval profile
      <select name="profile">
        <option :for={profile <- ~w(fast balanced thorough)} value={profile} selected={profile == @selected}>
          {profile}
        </option>
      </select>
    </label>
    """
  end

  defp limit(assigns) do
    ~H"""
    <label>
      Limit <span class="optional">optional</span>
      <input name="limit" type="number" min="1" step="1" placeholder="12" />
    </label>
    """
  end

  defp action_arguments(action, params) do
    McpTools
    |> Ash.Resource.Info.action(action)
    |> Map.fetch!(:arguments)
    |> Enum.reduce(%{}, fn argument, arguments ->
      parameter = if argument.name == :id, do: "_id", else: to_string(argument.name)

      case Map.get(params, parameter) do
        value when value in [nil, ""] -> arguments
        value -> Map.put(arguments, argument.name, value)
      end
    end)
  end

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
