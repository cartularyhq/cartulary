# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.ConsoleLive.Sources do
  @moduledoc """
  The provenance surface at `/console/sources`: the raw material knowledge was
  extracted from, before any of it became a governed statement.

  Two kinds of source arrive in Cartulary and both are shown here:

  - **Observations.** What someone actually said, grouped into sessions. A
    message is durable and immutable; the statements extracted from it are
    separate rows with their own lifecycle.
  - **Documents.** Uploaded or connector-synced files. A document is versioned
    immutably: a changed document appends a version and supersedes the stale
    derivations rather than overwriting history, and a remote deletion leaves a
    tombstone rather than a hole.

  ## Why raw content is shown

  A person cannot judge an extracted statement without being able to read what
  it was extracted from. This page is that check. Everything on it passed the
  same scope authorization as the statements themselves.

  That text is for the browser only. Document bytes, extracted text, connector
  cursors, source metadata, and secrets must never be copied into audit
  metadata, telemetry, or job arguments — and nothing here writes any of them
  anywhere.

  ## What is not shown

  Document chunks and their embedding vectors are rebuildable derived caches
  with no meaning to a reader, so they are reported as counts and nothing more.
  Connector secrets are stored as references and are never rendered; the
  connector rows show only status, schedule, and error class.

  This page performs no writes.
  """

  use CartularyWeb, :live_view

  import CartularyWeb.ConsoleComponents

  alias CartularyWeb.Console.Loader

  @doc """
  Loads the most recent documents, versions, sessions, observations, and
  connector configurations the reader may see.
  """
  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :sources, Loader.sources(socket.assigns.current_actor))}
  end

  @doc """
  Renders the four source panels, newest first in each.
  """
  @impl true
  def render(assigns) do
    ~H"""
    <.shell actor={@current_actor} active={:sources} title="Sources" flash={@flash}>
      <:subtitle>
        What knowledge was extracted from. Raw observations and document versions are durable
        and immutable; the statements drawn from them live their own lives.
      </:subtitle>

      <.panel
        title="Documents"
        description="Each document keeps every version it has ever had. A changed document appends; a removed one is tombstoned rather than deleted."
      >
        <.empty :if={@sources.documents == []} message="No document is readable in your scopes." />

        <article :for={document <- @sources.documents} class="record">
          <header class="record-head">
            <h3>{document.title}</h3>
            <div class="badge-row">
              <.badge family="state" value={document.status} />
              <.badge family="kind" value={document.source_kind} />
              <span :if={document.tombstoned_at} class="badge state-retracted">tombstoned</span>
            </div>
          </header>
          <p class="muted">
            {scope_path(@sources.scope_paths, document.scope_id)}
            <span :if={document.source_uri}> · {document.source_uri}</span>
          </p>

          <table class="grid compact">
            <thead>
              <tr>
                <th>Version</th>
                <th>Recorded</th>
                <th>Media type</th>
                <th>Bytes</th>
                <th>Chunks</th>
                <th>Processing</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={version <- Map.get(@sources.versions_by_document, document.id, [])}>
                <td class="nowrap">
                  v{version.version}
                  <span :if={version.id == document.current_version_id} class="badge">current</span>
                </td>
                <td class="nowrap muted">{timestamp(version.occurred_at)}</td>
                <td>{version.media_type}</td>
                <td class="nowrap">{version.byte_size}</td>
                <td class="nowrap">
                  {version.embedded_chunk_count}/{version.chunk_count}
                </td>
                <td>
                  <.badge family="state" value={version.processing_status} />
                  <span :if={version.last_error_class} class="muted">
                    {version.last_error_class}
                  </span>
                </td>
              </tr>
            </tbody>
          </table>
        </article>
      </.panel>

      <.panel
        title="Connectors"
        description="Where documents sync from. A cursor advances only after a page is durably handled, so a failed sync repeats rather than skipping."
      >
        <.empty :if={@sources.connectors == []} message="No connector is configured." />
        <table :if={@sources.connectors != []} class="grid">
          <thead>
            <tr>
              <th>Name</th>
              <th>Kind</th>
              <th>Scope</th>
              <th>Status</th>
              <th>Last synced</th>
              <th>Next sync</th>
              <th>Failures</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={connector <- @sources.connectors}>
              <td>{connector.name}</td>
              <td><.badge family="kind" value={connector.kind} /></td>
              <td>{scope_path(@sources.scope_paths, connector.scope_id)}</td>
              <td>
                <.badge family="state" value={connector.status} />
                <span :if={connector.last_error_class} class="muted">
                  {connector.last_error_class}
                </span>
              </td>
              <td class="nowrap muted">{timestamp(connector.last_synced_at)}</td>
              <td class="nowrap muted">{timestamp(connector.next_sync_at)}</td>
              <td class="nowrap">{connector.consecutive_failures}</td>
            </tr>
          </tbody>
        </table>
      </.panel>

      <.panel
        title="Sessions"
        description="Conversations observations arrived in. A session belongs to one scope and one peer, and may be linked to further scopes."
      >
        <.empty :if={@sources.sessions == []} message="No session is readable in your scopes." />
        <table :if={@sources.sessions != []} class="grid">
          <thead>
            <tr>
              <th>External id</th>
              <th>Scope</th>
              <th>Peer</th>
              <th>Status</th>
              <th>Opened</th>
              <th>Closed</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={session <- @sources.sessions}>
              <td>{session.external_id}</td>
              <td>{scope_path(@sources.scope_paths, session.scope_id)}</td>
              <td><.id_chip value={session.peer_id} /></td>
              <td><.badge family="state" value={session.status} /></td>
              <td class="nowrap muted">{timestamp(session.opened_at)}</td>
              <td class="nowrap muted">{timestamp(session.closed_at)}</td>
            </tr>
          </tbody>
        </table>
      </.panel>

      <.panel
        title="Observations"
        description="The raw record, exactly as submitted. Nothing here is knowledge yet — extraction proposes statements and the gates decide what is kept."
      >
        <.empty
          :if={@sources.messages == []}
          message="No observation is readable in your scopes."
        />
        <article :for={message <- @sources.messages} class="quote">
          <p class="quote-meta">
            <.badge family="kind" value={message.role} />
            {timestamp(message.occurred_at)} · {scope_path(@sources.scope_paths, message.scope_id)} · peer
            <.id_chip value={message.peer_id} />
            <span :if={message.extraction_completed_at} class="muted">· extracted</span>
          </p>
          <p>{message.content}</p>
        </article>
      </.panel>
    </.shell>
    """
  end
end
