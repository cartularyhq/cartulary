# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.Plugs.TraceContext do
  @moduledoc """
  Gives every HTTP response a trace correlation id and puts the same id into
  the log metadata for that request.

  The contract this plug maintains, which callers and operators rely on:

  - **Every response carries `x-trace-id`.** It is present whether or not
    distributed tracing is switched on, so an operator can always copy an id
    out of a response and find the matching log lines.
  - **A caller who sends a W3C `traceparent` keeps their trace id.** The
    response reports back the same 32-hex-character trace id the caller sent,
    so a request that is one hop in a larger distributed trace stays joined to
    it instead of starting a disconnected trace.
  - **A caller who sends no `traceparent` gets a freshly generated id**, unique
    to that request.
  - **`x-span-id` appears only when a real span exists.** When tracing is
    enabled and an OpenTelemetry span is active for the request, both headers
    report that span's ids, so the header values match what was exported to the
    collector. With tracing disabled there is no span id to report and the
    header is omitted rather than filled with a placeholder.

  ## Content safety

  The headers and the log metadata carry opaque ids only. Never widen this plug
  to echo an Account key, peer id, credential, path parameter, or any request
  content into a response header or into `Logger.metadata/1` — response headers
  and logs sit outside the governed memory boundary.

  ## Placement

  It runs in the endpoint, ahead of routing and parsing, so the id exists
  before any application code executes and is available even on responses
  produced by error handling. It does not start a span of its own; it only
  observes whichever span the tracing instrumentation created.
  """

  import Plug.Conn

  @trace_id_header "x-trace-id"
  @span_id_header "x-span-id"
  @traceparent_header "traceparent"

  # 16 bytes = 128 bits, the trace-id width the W3C trace-context format
  # defines. Hex-encoding it yields the required 32 lowercase characters.
  @trace_id_bytes 16

  @doc """
  Plug callback. Options are unused; whatever is passed is returned unchanged.
  """
  def init(opts), do: opts

  @doc """
  Sets the request's log metadata and arranges for the trace headers to be
  written when the response is sent.

  Always returns the connection unchanged apart from one assign and the
  registered callback; a malformed inbound `traceparent` is treated as absent
  and never fails the request.
  """
  def call(conn, _opts) do
    # Resolved once, up front, so that the id written into the log metadata is
    # the identical id the response header will report. Recomputing it in the
    # before-send callback would emit a different random id to the caller than
    # the one in the logs.
    fallback_trace_id = trace_id_from_traceparent(conn) || random_trace_id()

    case current_trace_context() do
      {:ok, trace_id, span_id} -> Logger.metadata(trace_id: trace_id, span_id: span_id)
      :error -> Logger.metadata(trace_id: fallback_trace_id)
    end

    assign(conn, :cartulary_fallback_trace_id, fallback_trace_id)
    |> register_before_send(&put_trace_headers/1)
  end

  # Deferred to send time rather than done in call/2 because the active span is
  # created by request instrumentation that runs after this plug; asking for it
  # now would usually find nothing.
  defp put_trace_headers(conn) do
    case current_trace_context() do
      # A live span wins over the inbound or generated id: these are the ids
      # actually exported to the tracing backend, so a header pointing anywhere
      # else would send an operator looking for a trace that does not exist.
      {:ok, trace_id, span_id} ->
        conn
        |> put_resp_header(@trace_id_header, trace_id)
        |> put_resp_header(@span_id_header, span_id)

      # No span: still emit a trace id so the response is correlatable, but no
      # span id, because inventing one would imply a span that was never
      # recorded.
      :error ->
        put_resp_header(conn, @trace_id_header, conn.assigns.cartulary_fallback_trace_id)
    end
  end

  # Reads the ambient OpenTelemetry span, if any. With tracing disabled the SDK
  # still answers, but with the all-zero "invalid" ids, so both ids are
  # validated before being trusted.
  defp current_trace_context do
    span_ctx = OpenTelemetry.Tracer.current_span_ctx()

    with true <- span_ctx != :undefined,
         trace_id when is_binary(trace_id) <- OpenTelemetry.Span.hex_trace_id(span_ctx),
         span_id when is_binary(span_id) <- OpenTelemetry.Span.hex_span_id(span_ctx),
         true <- valid_trace_id?(trace_id),
         true <- valid_span_id?(span_id) do
      {:ok, trace_id, span_id}
    else
      _ -> :error
    end
  end

  defp trace_id_from_traceparent(conn) do
    conn
    |> get_req_header(@traceparent_header)
    |> List.first()
    |> parse_traceparent()
  end

  # Accepts only version "00" of the W3C traceparent format, with its exact
  # field widths: version-traceid-spanid-flags. The caller's span id and sampling
  # flags are intentionally ignored — this plug propagates the trace identity
  # back to the caller, it does not adopt the caller's parent span.
  defp parse_traceparent(
         <<"00-", trace_id::binary-size(32), "-", _span_id::binary-size(16), "-",
           _flags::binary-size(2)>>
       ) do
    if valid_trace_id?(trace_id), do: trace_id
  end

  # Any other shape, or no header at all, means "no usable inbound trace". A bad
  # header from an upstream caller must degrade to a fresh id, never to an error.
  defp parse_traceparent(_traceparent), do: nil

  # An all-zero id is the format's explicit "invalid" sentinel. Accepting it
  # would stamp every response with the same meaningless correlation id.
  defp valid_trace_id?(trace_id) do
    String.match?(trace_id, ~r/\A[0-9a-f]{32}\z/) and trace_id != String.duplicate("0", 32)
  end

  # Span ids are half the width of trace ids: 8 bytes, 16 lowercase hex chars.
  defp valid_span_id?(span_id) do
    String.match?(span_id, ~r/\A[0-9a-f]{16}\z/) and span_id != String.duplicate("0", 16)
  end

  # Cryptographically strong bytes, not a counter or timestamp: ids from
  # separate nodes and separate runs must not collide when logs are merged.
  defp random_trace_id do
    @trace_id_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end
end
