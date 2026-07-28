# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.ConsoleComponents do
  @moduledoc """
  The shared visual vocabulary of the browser console: the page shell, the
  navigation, and the small pieces every page reuses.

  Each function here is a stateless component. None of them queries, decides
  authorization, or holds state; they take already-authorized data and render
  it. The one authorization-shaped thing they do is *hide* navigation entries
  and controls the viewer cannot use, and that is presentation only — the
  operation layer refuses a forged event regardless of what was rendered.

  ## Styling

  Every visual decision lives in `priv/static/assets/console.css`, which the
  root layout links. Components emit class names and no inline `style`
  attributes, so a change of appearance is a change to one file. The stylesheet
  is served from this origin, which the browser pipeline's
  Content-Security-Policy permits; do not move rules into markup on the
  assumption that inline styles are always allowed, and do not add a `<script>`
  of any kind, because the same policy forbids inline script and permits only
  same-origin modules.

  ## Content safety

  These components render knowledge statements, raw observations, and document
  titles, because a person who is authorized to read them has to be able to
  read them. That text is for the browser and nowhere else: never copy a value
  passed to one of these components into a log line, a telemetry attribute, an
  audit entry, or a background-job argument.
  """

  use CartularyWeb, :html

  alias Cartulary.Actor
  alias CartularyWeb.Console.Access

  @doc """
  The outer page frame: identity bar, navigation, flash messages, and the
  page's own content.

  Required attributes are the signed-in `actor`, the `active` navigation key,
  the page `title`, and the `flash` map. The `inner_block` slot carries the
  page. An optional `subtitle` slot renders one line of orientation under the
  heading.

  The navigation is filtered by what the viewer may reach: the curator queue
  appears only for curators and account administrators, and the operations page
  only for account administrators. Hiding an entry is a convenience, not a
  control — both destinations re-check authority when they are opened.
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
  A single navigation entry.

  Entries whose `:external?` flag is set render as a plain anchor rather than a
  live navigation link. That flag marks a destination in a different live
  session — the curator queue — where a live patch cannot carry the socket
  across, so the browser must perform a full load.
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
  One dashboard statistic: a large number, a label, and an optional note.

  `tone` tints the tile and takes `"neutral"`, `"accent"`, `"warn"`, or
  `"danger"`. Use `"warn"` for a figure that wants attention (work waiting) and
  `"danger"` only for one that means something is wrong.
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
  A horizontal bar chart of labelled counts, drawn with plain elements sized as
  a percentage of the largest bar.

  `rows` is a list of `{label, count}` tuples. Zero-count rows are kept rather
  than dropped, because "none of these" is information a reader wants — an
  absent row reads as an absent category.
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
  A small coloured label for a lifecycle state, sensitivity, kind, or any other
  short enumerated value.

  `family` names the CSS group so the same word can be tinted differently in
  different columns — `"state"`, `"sensitivity"`, `"kind"`, `"level"`,
  `"decision"`.
  """
  attr :family, :string, required: true
  attr :value, :any, required: true

  def badge(assigns) do
    ~H"""
    <span class={["badge", "#{@family}-#{@value}"]}>{@value}</span>
    """
  end

  @doc """
  A monospaced identifier, shortened for reading and carrying the full value as
  a tooltip.

  Identifiers are shown throughout the console because they are how a reader
  moves between a statement, the observation it came from, and the decision
  that governed it. Showing only the first segment keeps a table legible while
  the tooltip keeps the value copyable.
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
  Placeholder for a panel with nothing in it.

  An empty console panel is usually a correct answer rather than a failure —
  a reader with no grant on a scope, or an Account with no documents yet — so
  the message should say what would appear here, not apologise.
  """
  attr :message, :string, required: true

  def empty(assigns) do
    ~H"""
    <p class="empty">{@message}</p>
    """
  end

  @doc """
  A titled panel with optional description, the standard container for every
  list and table in the console.
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
  Formats a timestamp for display, or renders an explicit dash when it is
  absent.

  Times are rendered in UTC with second precision. The console does not guess
  at a reader's timezone: belief time and valid time are compared against each
  other far more often than against the wall clock, and a silently localised
  timestamp makes those comparisons wrong when the reader travels.
  """
  def timestamp(nil), do: "—"

  def timestamp(%DateTime{} = at) do
    at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  def timestamp(other), do: to_string(other)

  @doc """
  Shortens a value for display, appending an ellipsis when it was cut.

  Used for statement text in dense tables. The full text is always available on
  the statement's own page, so truncation here loses nothing.
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
  Renders a scope path, or a visible marker when the path could not be
  resolved.

  An unresolved path means a row surfaced from a scope the viewer cannot read,
  which is a policy defect. It is shown as an explicit marker rather than
  blanked, so the defect is noticed instead of looking like an empty column.
  """
  def scope_path(paths, scope_id), do: Map.get(paths, scope_id) || "(unreadable scope)"

  # The complete navigation, filtered to what this viewer can reach. The order
  # is the order a person tends to want it: overview, then the memory itself,
  # then where it came from, then what to do about it.
  defp nav_items(%Actor{} = actor) do
    base = [
      %{key: :dashboard, label: "Overview", glyph: "◉", path: "/console"},
      %{key: :knowledge, label: "Knowledge", glyph: "◇", path: "/console/knowledge"},
      %{key: :scopes, label: "Scopes", glyph: "▤", path: "/console/scopes"},
      %{key: :graph, label: "Graph", glyph: "⁂", path: "/console/graph"},
      %{key: :sources, label: "Sources", glyph: "❑", path: "/console/sources"},
      %{key: :skills, label: "Skills", glyph: "◈", path: "/console/skills"},
      %{key: :me, label: "About me", glyph: "☺", path: "/console/me"}
    ]

    # The curator queue lives in its own live session behind a stricter mount
    # hook, so it is reached by a full page load rather than a live patch.
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

  # Bar widths are the one place a computed style attribute is unavoidable: the
  # value is data, so it cannot live in a stylesheet. The browser policy allows
  # inline style attributes; it forbids inline script, which this is not.
  defp bar_width(_count, 0), do: "width:0%"

  defp bar_width(count, max) do
    "width:#{Float.round(count / max * 100, 1)}%"
  end

  defp short_id(nil), do: "—"

  defp short_id(value) do
    value |> to_string() |> String.slice(0, 8)
  end
end
