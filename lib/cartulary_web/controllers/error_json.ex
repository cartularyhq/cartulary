# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.ErrorJSON do
  @moduledoc """
  Renders the body for any JSON request that ends in an error status.

  Configured as the endpoint's only `render_errors` format, so it is reached whenever a
  request raises or halts with an error status and no controller produced a body: an
  unmatched route, a malformed request, or an unhandled exception. Domain errors raised by
  the controllers land here too; nothing gives them a status of their own, so they arrive
  as a 500 unless the exception itself declares otherwise.

  ## This is the last thing an unauthenticated stranger sees

  The body must stay generic. Phoenix hands an error view the connection along with the
  raised reason and stack, so the ability to leak is right there in the assigns — which is
  exactly why the clause below ignores them. Never echo an exception message, stack data,
  SQL, changeset internals, resource names, or any part of the request: this path is
  reachable without credentials, so whatever appears here is disclosed to anyone who can
  provoke an error. The status code carries the useful signal; operators correlate the
  specifics through the `x-trace-id` header and the server logs.
  """

  @doc """
  Builds the error body for a rendered error template.

  `template` is the Phoenix error template name, such as `"404.json"`. Returns
  `%{errors: %{detail: message}}`, where the message is the standard HTTP status text
  derived from that template name — `"404.json"` becomes `"Not Found"`.

  One catch-all clause covers every status on purpose. A per-status clause added above
  this one would still have to keep its message generic; the only reason to add one is
  wording, never to expose what actually went wrong.
  """
  def render(template, _assigns) do
    %{errors: %{detail: Phoenix.Controller.status_message_from_template(template)}}
  end
end
