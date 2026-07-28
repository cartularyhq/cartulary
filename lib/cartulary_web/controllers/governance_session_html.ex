# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.GovernanceSessionHTML do
  @moduledoc """
  The rendered pages for curator sign-in.

  Each template file in the sibling `governance_session_html/` directory is compiled into
  a function named after the file, so `new.html.heex` becomes `new/1`. Adding a file there
  adds a renderable page; nothing else is needed here.

  These pages are served before anyone is authenticated. They must therefore show no
  memory, no knowledge, no peer or account details, and nothing about why a sign-in
  attempt failed beyond a generic notice — everything rendered here is visible to whoever
  loads the URL.
  """

  use CartularyWeb, :html

  embed_templates "governance_session_html/*"
end
