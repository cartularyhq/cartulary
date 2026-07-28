# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Documents.Connector do
  @moduledoc """
  The contract an external document source must implement to be synced incrementally.

  An adapter has exactly one job: given a cursor, return the next page of raw items and the
  cursor that follows it. It fetches; it does not decide. Whether an item becomes a new version,
  a no-op, or a tombstone is worked out by the sync service from the bytes themselves, and an
  adapter must never write documents, chunks, or knowledge of its own.

  ## Implementing `pull/2`

  Return `{:ok, page}` with the items following the given cursor, the cursor that comes after
  them, and `:has_more?` when further pages are waiting — the service will chain another run
  rather than looping inside one job.

  Two rules matter more than anything else in an adapter:

  - **Return whole bytes, not diffs.** Sync decides what changed by hashing the payload and
    comparing it against the document's current hash. Identical bytes are a free no-op, so it
    costs nothing to re-emit an item the adapter is unsure about, and it is never correct to
    withhold one.
  - **The cursor must be replay-safe.** The service applies the whole page before it saves the
    new cursor, so a crash re-fetches the same page. A cursor that means "everything up to and
    including what I just handed over" is safe; one that assumes the previous page was consumed
    exactly once is not.

  ## Content safety

  Items carry document bytes and source metadata, which are content. An adapter must not log
  them, must not put them in telemetry, and must not resolve a credential into the cursor or
  the connector's stored settings — connector configuration holds secret *references* only.
  """

  @typedoc """
  One item from a source page.

  `:external_id` is the source's own stable identifier and is required; it is how repeated syncs
  recognise the same document. `:bytes` is required for a live item and must be the complete
  current payload. `:deleted?` marks a removal at the source, in which case `:bytes` is not
  read and the document is tombstoned rather than erased. `:title`, `:media_type`,
  `:source_uri`, `:metadata`, and `:occurred_at` are optional descriptive fields; the title
  falls back to the external id and the media type to a generic binary type.
  """
  @type item :: %{
          required(:external_id) => String.t(),
          optional(:title) => String.t(),
          optional(:media_type) => String.t(),
          optional(:bytes) => binary(),
          optional(:source_uri) => String.t(),
          optional(:metadata) => map(),
          optional(:deleted?) => boolean(),
          optional(:occurred_at) => DateTime.t()
        }

  @typedoc """
  One page of results.

  `:items` may be empty. `:cursor` is the adapter-defined resume point that follows this page
  and is stored verbatim on the connector once the page has been durably handled. `:has_more?`
  asks the service to schedule an immediate follow-up run instead of waiting for the next
  interval.
  """
  @type page :: %{
          required(:items) => [item()],
          required(:cursor) => map(),
          optional(:has_more?) => boolean()
        }

  @doc """
  Fetches the items following `cursor` for this connector.

  The cursor is the map the adapter itself returned last time, or the empty map on a first run.
  Return `{:ok, page}` or `{:error, reason}`; on error the service records an error class, backs
  the connector off by one polling interval, and leaves the cursor untouched so the same page is
  retried.
  """
  @callback pull(Cartulary.Documents.ConnectorConfig.t(), map()) ::
              {:ok, page()} | {:error, term()}

  @doc """
  Looks up the adapter module registered for a connector kind.

  Adapters are registered per deployment in application configuration; none ship enabled, so an
  installation only syncs the sources its operator deliberately wired up.

  Raises `ArgumentError` when the kind has no registered adapter. A connector row can outlive
  the adapter that served it — after a configuration change or a downgrade — and this is how
  that shows up, at sync time rather than silently doing nothing.
  """
  def adapter!(kind) when is_binary(kind) do
    adapters =
      :cartulary
      |> Application.fetch_env!(:documents)
      |> Keyword.fetch!(:connector_adapters)

    Map.get(adapters, kind) ||
      raise ArgumentError, "connector adapter is not configured for #{inspect(kind)}"
  end
end
