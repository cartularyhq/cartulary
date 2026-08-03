# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.ConsoleComponents do
  @moduledoc """
  Stateless presentation components for the browser console.

  They render already-authorized data and may hide unavailable navigation, but
  never authorize operations. Styling belongs in `console.css`; inline scripts
  violate the console CSP. The computed chart width is the only inline style.
  Never copy rendered content into logs, telemetry, audit data, or job args.
  """

  use CartularyWeb, :html

  alias Cartulary.Actor
  alias CartularyWeb.Console.Access

  @doc """
  Renders the identity bar, role-filtered navigation, flash messages, and page
  slots. Destinations enforce authorization independently.
  """
  attr :actor, Actor, required: true
  attr :active, :atom, required: true
  attr :title, :string, required: true
  attr :flash, :map, default: %{}
  slot :subtitle
  slot :actions
  slot :inner_block, required: true

  def shell(assigns) do
    assigns = assign(assigns, :nav_items, nav_items(assigns.actor))

    ~H"""
    <div class="app">
      <header class="topbar">
        <a class="brand" href={~p"/console"}>
          <span class="brand-mark">◈</span>
          <span class="brand-name">Cartulary</span>
        </a>

        <div class="identity">
          <span class="role-pill">{Access.role_label(@actor)}</span>
          <span class="account-key">{@actor.account_key}</span>
          <%!--
            Sign-out is a form POST rather than a link because it destroys
            server session state. The hidden _method turns the POST into the
            DELETE route and the CSRF token is mandatory. A GET link would let
            a third-party page sign the reader out, and would set the precedent
            that browser state changes may travel by GET.
          --%>
          <form method="post" action={~p"/sign-out"}>
            <input type="hidden" name="_method" value="delete" />
            <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
            <button class="ghost">Sign out</button>
          </form>
        </div>
      </header>

      <div class="body">
        <nav class="sidebar">
          <.nav_link :for={item <- @nav_items} item={item} active={@active} />
        </nav>

        <main class="content">
          <div class="page-head">
            <div>
              <h1>{@title}</h1>
              <p :if={@subtitle != []} class="lede">{render_slot(@subtitle)}</p>
            </div>
            <div :if={@actions != []} class="page-actions">{render_slot(@actions)}</div>
          </div>

          <p :if={Phoenix.Flash.get(@flash, :info)} class="flash info" role="status">
            {Phoenix.Flash.get(@flash, :info)}
          </p>
          <p :if={Phoenix.Flash.get(@flash, :error)} class="flash error" role="alert">
            {Phoenix.Flash.get(@flash, :error)}
          </p>

          {render_slot(@inner_block)}
        </main>
      </div>
    </div>
    """
  end

  @doc """
  Renders one navigation entry as a full-load anchor.
  """
  attr :item, :map, required: true
  attr :active, :atom, required: true

  def nav_link(assigns) do
    ~H"""
    <a
      href={@item.path}
      class={["nav-item", @item.key == @active && "is-active"]}
      aria-current={@item.key == @active && "page"}
    >
      <span class="nav-glyph" aria-hidden="true">{@item.glyph}</span>
      <span>{@item.label}</span>
    </a>
    """
  end

  @doc """
  Renders a labelled statistic with an optional note and destination.

  `tone` is `"neutral"`, `"accent"`, `"warn"`, or `"danger"`.
  """
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :note, :string, default: nil
  attr :tone, :string, default: "neutral"
  attr :navigate, :string, default: nil

  def tile(assigns) do
    ~H"""
    <div class={["tile", "tone-#{@tone}"]}>
      <p class="tile-value">{@value}</p>
      <p class="tile-label">{@label}</p>
      <p :if={@note} class="tile-note">{@note}</p>
      <a :if={@navigate} class="tile-link" href={@navigate}>Explore</a>
    </div>
    """
  end

  @doc """
  Renders `{label, count}` rows relative to the largest count, including zeros.
  """
  attr :rows, :list, required: true
  attr :class_prefix, :string, default: "bar"

  def bar_chart(assigns) do
    max = assigns.rows |> Enum.map(fn {_label, count} -> count end) |> Enum.max(fn -> 0 end)
    assigns = assign(assigns, :max, max)

    ~H"""
    <div class="bars">
      <div :for={{label, count} <- @rows} class="bar-row">
        <span class="bar-label">{label}</span>
        <span class="bar-track">
          <span class={["bar-fill", "#{@class_prefix}-#{label}"]} style={bar_width(count, @max)}>
          </span>
        </span>
        <span class="bar-count">{count}</span>
      </div>
    </div>
    """
  end

  @doc """
  Renders an enumerated value using its `family` CSS group.
  """
  attr :family, :string, required: true
  attr :value, :any, required: true

  def badge(assigns) do
    ~H"""
    <span class={["badge", "#{@family}-#{@value}"]}>{@value}</span>
    """
  end

  @doc """
  Renders a shortened identifier with the full value in its tooltip.
  """
  attr :value, :any, required: true
  attr :navigate, :string, default: nil

  def id_chip(assigns) do
    ~H"""
    <a :if={@navigate} class="chip" href={@navigate} title={@value}>{short_id(@value)}</a>
    <span :if={is_nil(@navigate)} class="chip" title={@value}>{short_id(@value)}</span>
    """
  end

  @doc """
  Renders a caller-supplied empty-state message.
  """
  attr :message, :string, required: true

  def empty(assigns) do
    ~H"""
    <p class="empty">{@message}</p>
    """
  end

  @doc """
  Renders a titled panel with an optional description.
  """
  attr :title, :string, required: true
  attr :description, :string, default: nil
  slot :inner_block, required: true

  def panel(assigns) do
    ~H"""
    <section class="panel">
      <header class="panel-head">
        <h2>{@title}</h2>
        <p :if={@description}>{@description}</p>
      </header>
      {render_slot(@inner_block)}
    </section>
    """
  end

  @doc """
  Formats a timestamp in UTC with second precision, or `—` when absent.
  """
  def timestamp(nil), do: "—"

  def timestamp(%DateTime{} = at) do
    at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  def timestamp(other), do: to_string(other)

  @doc """
  Truncates display text to `length` characters and appends an ellipsis.
  """
  def truncate(nil, _length), do: ""

  def truncate(text, length) when is_binary(text) do
    if String.length(text) > length do
      String.slice(text, 0, length) <> "…"
    else
      text
    end
  end

  @doc """
  Returns a scope path or an explicit marker for an unreadable scope.
  """
  def scope_path(paths, scope_id), do: Map.get(paths, scope_id) || "(unreadable scope)"

  # Keep navigation task-ordered and role-filtered.
  defp nav_items(%Actor{} = actor) do
    base = [
      %{key: :dashboard, label: "Overview", glyph: "◉", path: "/console"},
      %{key: :knowledge, label: "Knowledge", glyph: "◇", path: "/console/knowledge"},
      %{key: :scopes, label: "Scopes", glyph: "▤", path: "/console/scopes"},
      %{key: :graph, label: "Graph", glyph: "⁂", path: "/console/graph"},
      %{key: :sources, label: "Sources", glyph: "❑", path: "/console/sources"},
      %{key: :skills, label: "Skills", glyph: "◈", path: "/console/skills"},
      %{key: :tools, label: "Tool workbench", glyph: "⌘", path: "/console/tools"},
      %{key: :me, label: "About me", glyph: "☺", path: "/console/me"}
    ]

    # Governance uses a separate live session and requires a full load.
    curator =
      if Access.can?(actor, :curate),
        do: [%{key: :queue, label: "Governance queue", glyph: "⚖", path: "/governance"}],
        else: []

    admin =
      if Access.can?(actor, :administer),
        do: [%{key: :operations, label: "Operations", glyph: "⚙", path: "/console/operations"}],
        else: []

    base ++ curator ++ admin
  end

  # Data-driven widths cannot be predefined in the stylesheet.
  defp bar_width(_count, 0), do: "width:0%"

  defp bar_width(count, max) do
    "width:#{Float.round(count / max * 100, 1)}%"
  end

  defp short_id(nil), do: "—"

  defp short_id(value) do
    value |> to_string() |> String.slice(0, 8)
  end
end
