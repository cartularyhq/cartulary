# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.Plugs.MeterUsage do
  @moduledoc false

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    register_before_send(conn, fn response ->
      actor = response.assigns[:current_actor]

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

  defp operation(%{method: "POST", request_path: "/api/v1/ingest"}), do: "api.ingest"

  defp operation(%{request_path: path}),
    do: "api." <> (path |> Path.basename() |> String.downcase())
end
