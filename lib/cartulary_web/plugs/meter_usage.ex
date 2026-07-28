# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.Plugs.MeterUsage do
  @moduledoc """
  Records one usage-ledger entry per authenticated API request.

  The ledger it feeds is the append-only record of what an Account actually
  consumed: it backs per-Account request and ingest counts, the daily budget
  counters, and the self-host cost view. Because operators bill or budget
  against it, the entry must be written for failed requests too, not only for
  successful ones.

  ## Why the work happens in a before-send callback

  The final HTTP status is not known until the controller has run and the
  response is about to be sent, and the entry records that status. Registering
  a before-send callback is therefore not an optimisation — writing at the
  front of the plug would record every request as if it had succeeded.

  Deferring to send time also means a request that a later plug or the
  controller rejects is still recorded, carrying the rejection status. That is
  intended: a rejected call consumed capacity. Only a `5xx` is classified as
  `error`; everything below it is `ok`, so a client error counts as ordinary
  consumed usage rather than as a server fault.

  ## Content safety is mandatory

  Only three things travel from the request into the ledger entry: a coarse
  operation name derived from the route, the numeric HTTP status, and an
  `ok`/`error` class. Request and response bodies, parameters, statements,
  prompts, questions, answers, document text, and the presented credential must
  never be added here. The ledger is readable by operators and is exported in
  operational summaries, so anything written to it is effectively disclosed
  outside the governed memory boundary.

  ## Ordering requirement

  It reads `conn.assigns.current_actor` and so must run after authentication.
  Anonymous requests are not metered: there is no Account to attribute them to,
  and attributing them to a guessed Account would corrupt another tenant's
  totals. The actor check is what keeps that true if the pipeline is ever
  reordered.
  """

  @behaviour Plug

  import Plug.Conn

  @doc """
  Plug callback. Options are unused; whatever is passed is returned unchanged.
  """
  @impl true
  def init(opts), do: opts

  @doc """
  Registers the before-send callback that writes the usage entry.

  Returns the connection immediately; the ledger write happens later, when the
  response is flushed, and the response itself is passed through unmodified.
  """
  @impl true
  def call(conn, _opts) do
    register_before_send(conn, fn response ->
      actor = response.assigns[:current_actor]

      # No actor means the request never authenticated, so there is no Account
      # the usage can honestly be charged to. Skip rather than guess.
      if actor do
        Cartulary.Operations.Metering.record_api(actor, %{
          operation: operation(response),
          http_status: response.status,
          status: if(response.status < 500, do: "ok", else: "error")
        })
      end

      response
    end)
  end

  # Ingest is pinned to its literal operation name because the ingest budget
  # counter keys on exactly this string. Letting it fall through to the generic
  # derivation below would make a future route change silently stop counting
  # ingests instead of failing visibly.
  defp operation(%{method: "POST", request_path: "/api/v1/ingest"}), do: "api.ingest"

  # Everything else is named after the last path segment only. Dropping the
  # earlier segments keeps the ledger's operation cardinality bounded and, more
  # importantly, keeps record ids embedded in a path (as in a per-item
  # governance action) out of the durable usage entry.
  defp operation(%{request_path: path}),
    do: "api." <> (path |> Path.basename() |> String.downcase())
end
