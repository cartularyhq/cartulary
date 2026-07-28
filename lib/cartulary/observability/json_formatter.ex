# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Observability.JSONFormatter do
  @moduledoc """
  Production log formatter: one JSON object per line, with credentials redacted
  and metadata reduced to a reviewed allowlist.

  Logs are shipped off the node and retained, often into systems with looser
  access control than the database they describe. This formatter is the last
  place a secret or a piece of stored content can be stopped, so it works by
  exclusion: metadata is dropped unless it is explicitly allowed, and message
  text is scrubbed for credential-shaped substrings on the way out.

  ## Two independent defences

  The allowlist handles structured metadata — a library that helpfully attaches
  a query, a parameter map, or an actor struct contributes nothing, because its
  key is not on the list. Redaction handles free text, where a credential can
  appear inside a message nobody intended to log. Neither is sufficient alone,
  and neither should be relaxed to make a debugging session easier.

  Adding a key to the allowlist is a disclosure decision. Ids, correlation
  handles, and code locations are safe; anything that can carry a value from a
  request, a document, or a model is not.

  ## Never breaks logging

  A formatter that raises takes the whole logging handler down with it and, in
  the worst case, silences the system exactly when something is going wrong.
  Any failure while formatting is therefore caught and replaced with a fixed
  marker line. That line contains no part of the original message, since the
  content that broke formatting is precisely the content that must not be
  emitted unscrubbed.
  """

  # Correlation handles and code locations only. Everything else a library
  # attaches is dropped. Notably absent: anything that could hold a query, an
  # actor, request parameters, or an Account key.
  @safe_metadata ~w(request_id trace_id span_id module function line pid application)a

  # Matches a credential-looking assignment and everything up to the next comma
  # or whitespace, so the value is removed along with its key. Case-insensitive
  # because these appear in headers, config dumps, and prose alike.
  @sensitive_pattern ~r/(authorization|api[_-]?key|password|secret|token)=?[^,\s]*/i

  # Bearer tokens need their own pattern because the token follows a space
  # rather than an equals sign, and because one can appear in a line with no
  # credential-shaped key in front of it at all.
  @bearer_pattern ~r/Bearer\s+[A-Za-z0-9._~+\/=-]+/i

  @doc """
  Formats one log event as a single JSON line.

  Invoked by the logging handler, not by application code. Returns IO data — the
  encoded object followed by a newline — so that each event occupies exactly one
  line and stays parseable by a log shipper.

  Never raises: any failure yields a fixed error line instead, which keeps a
  malformed event from disabling the handler.
  """
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
    # The original event is deliberately not included. Whatever broke encoding
    # is exactly the value that has not been through redaction.
    _error -> ["{\"level\":\"error\",\"message\":\"logger_format_error\"}\n"]
  end

  # The event's own recorded time in microseconds, converted to an ISO 8601
  # string. Falls back to the current time when the handler supplies none, so a
  # line is never emitted without a timestamp — an unordered log is close to
  # useless during an incident.
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

  # Flattens the several shapes a log event can take into one string. The
  # inspect limits — 50 terms, 1000 printable characters — bound how much a
  # structured report or an unexpected term can contribute to a single line, so
  # one large term cannot fill the log. Every branch's output goes through
  # redaction afterwards.
  defp render_message({:string, value}), do: IO.chardata_to_string(value)
  defp render_message({:report, report}), do: inspect(report, limit: 50, printable_limit: 1_000)
  defp render_message(value) when is_binary(value), do: value
  defp render_message(value) when is_list(value), do: IO.chardata_to_string(value)
  defp render_message(value), do: inspect(value, limit: 50, printable_limit: 1_000)

  # Order matters. The bearer pass runs first because the assignment pattern
  # stops at whitespace: on "authorization=Bearer abc123" it would remove only
  # "authorization=Bearer" and leave the token itself in the log line.
  defp redact(message) do
    message
    |> String.replace(@bearer_pattern, "Bearer [REDACTED]")
    |> String.replace(@sensitive_pattern, "\\1=[REDACTED]")
  end

  # Allowlisted metadata is still not trusted. Strings are truncated to 256
  # characters and redacted; atoms, numbers, and booleans pass through as
  # themselves so the JSON keeps useful types; anything else is inspected under
  # tight limits and then redacted. Truncation is a bound on accidental
  # disclosure as much as on line length.
  defp safe_value(value) when is_binary(value), do: redact(String.slice(value, 0, 256))
  defp safe_value(value) when is_atom(value) or is_number(value) or is_boolean(value), do: value
  defp safe_value(value), do: inspect(value, limit: 10, printable_limit: 256) |> redact()
end
