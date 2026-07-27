# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.Plugs.TraceContext do
  @moduledoc """
  Adds trace correlation headers to every HTTP response.

  When OpenTelemetry has an active request span, the response headers expose the
  real OTel trace/span ids. If tracing is disabled or no span is active, the plug
  still provides a per-request trace-shaped correlation id for local logs.
  """

  import Plug.Conn

  @trace_id_header "x-trace-id"
  @span_id_header "x-span-id"
  @traceparent_header "traceparent"
  @trace_id_bytes 16

  def init(opts), do: opts

  def call(conn, _opts) do
    fallback_trace_id = trace_id_from_traceparent(conn) || random_trace_id()

    case current_trace_context() do
      {:ok, trace_id, span_id} -> Logger.metadata(trace_id: trace_id, span_id: span_id)
      :error -> Logger.metadata(trace_id: fallback_trace_id)
    end

    assign(conn, :cartulary_fallback_trace_id, fallback_trace_id)
    |> register_before_send(&put_trace_headers/1)
  end

  defp put_trace_headers(conn) do
    case current_trace_context() do
      {:ok, trace_id, span_id} ->
        conn
        |> put_resp_header(@trace_id_header, trace_id)
        |> put_resp_header(@span_id_header, span_id)

      :error ->
        put_resp_header(conn, @trace_id_header, conn.assigns.cartulary_fallback_trace_id)
    end
  end

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

  defp parse_traceparent(
         <<"00-", trace_id::binary-size(32), "-", _span_id::binary-size(16), "-",
           _flags::binary-size(2)>>
       ) do
    if valid_trace_id?(trace_id), do: trace_id
  end

  defp parse_traceparent(_traceparent), do: nil

  defp valid_trace_id?(trace_id) do
    String.match?(trace_id, ~r/\A[0-9a-f]{32}\z/) and trace_id != String.duplicate("0", 32)
  end

  defp valid_span_id?(span_id) do
    String.match?(span_id, ~r/\A[0-9a-f]{16}\z/) and span_id != String.duplicate("0", 16)
  end

  defp random_trace_id do
    @trace_id_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end
end
