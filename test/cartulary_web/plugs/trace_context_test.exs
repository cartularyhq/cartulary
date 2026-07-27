# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.Plugs.TraceContextTest do
  use CartularyWeb.ConnCase, async: true

  describe "trace response headers" do
    test "adds a trace id when the request has no trace context", %{conn: conn} do
      conn = get(conn, ~p"/api/health")

      assert [trace_id] = get_resp_header(conn, "x-trace-id")
      assert trace_id =~ ~r/\A[0-9a-f]{32}\z/
      refute trace_id == String.duplicate("0", 32)
    end

    test "preserves the incoming W3C trace id", %{conn: conn} do
      trace_id = "4bf92f3577b34da6a3ce929d0e0e4736"
      traceparent = "00-#{trace_id}-00f067aa0ba902b7-01"

      conn =
        conn
        |> put_req_header("traceparent", traceparent)
        |> get(~p"/api/health")

      assert get_resp_header(conn, "x-trace-id") == [trace_id]
    end
  end
end
