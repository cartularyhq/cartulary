# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.SessionHTML do
  @moduledoc """
  The rendered pages for console sign-in.

  Each template file in the sibling `session_html/` directory compiles into a
  function named after the file, so `new.html.heex` becomes `new/1`. Adding a
  file there adds a renderable page; nothing else is needed here.

  These pages are served to anonymous visitors. They must therefore show no
  memory, no account or peer details, and nothing about why an attempt failed
  beyond a generic notice — everything rendered here is visible to whoever
  loads the URL.
  """

  use CartularyWeb, :html

  embed_templates "session_html/*"
end
