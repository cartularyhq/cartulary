# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Observability.JSONFormatter do
  @moduledoc "Content-safe structured Logger formatter for production releases."

  @safe_metadata ~w(request_id trace_id span_id module function line pid application)a
  @sensitive_pattern ~r/(authorization|api[_-]?key|password|secret|token)=?[^,\s]*/i
  @bearer_pattern ~r/Bearer\s+[A-Za-z0-9._~+\/=-]+/i

  def format(%{level: level, msg: message, meta: metadata}, _config) do
    payload = %{
      timestamp: timestamp(metadata),
      level: Atom.to_string(level),
      message: message |> render_message() |> redact(),
      metadata:
        metadata
        |> Map.new()
        |> Map.take(@safe_metadata)
        |> Map.new(fn {key, value} -> {key, safe_value(value)} end)
    }

    [Jason.encode!(payload), "\n"]
  rescue
    _error -> ["{\"level\":\"error\",\"message\":\"logger_format_error\"}\n"]
  end

  defp timestamp(metadata) do
    case Map.get(Map.new(metadata), :time) do
      time when is_integer(time) ->
        time
        |> System.convert_time_unit(:microsecond, :millisecond)
        |> DateTime.from_unix!(:millisecond)

      _other ->
        DateTime.utc_now()
    end
    |> DateTime.to_iso8601()
  end

  defp render_message({:string, value}), do: IO.chardata_to_string(value)
  defp render_message({:report, report}), do: inspect(report, limit: 50, printable_limit: 1_000)
  defp render_message(value) when is_binary(value), do: value
  defp render_message(value) when is_list(value), do: IO.chardata_to_string(value)
  defp render_message(value), do: inspect(value, limit: 50, printable_limit: 1_000)

  defp redact(message) do
    message
    |> String.replace(@bearer_pattern, "Bearer [REDACTED]")
    |> String.replace(@sensitive_pattern, "\\1=[REDACTED]")
  end

  defp safe_value(value) when is_binary(value), do: redact(String.slice(value, 0, 256))
  defp safe_value(value) when is_atom(value) or is_number(value) or is_boolean(value), do: value
  defp safe_value(value), do: inspect(value, limit: 10, printable_limit: 256) |> redact()
end
