# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.Layouts do
  @moduledoc """
  The single HTML document shell wrapped around every browser page.

  Cartulary's only browser surface is the human curator area: the password sign-in page and
  the governance LiveView. Both render inside `root/1`; there is no second, nested layout, and
  LiveViews are configured to skip one, so this file is the one place the document head, the
  CSRF token, and the client bootstrap exist.

  The JSON API never reaches this module. API responses are rendered without a layout.
  """

  use CartularyWeb, :html

  @doc """
  Renders the outer HTML document for the curator browser pages.

  Three details here are load-bearing and easy to break while tidying up:

  - The `csrf-token` meta tag is what the LiveView client reads to authenticate its socket
    connection; remove it and the live socket silently fails to connect. The forms on these
    pages do not use it — they carry their own hidden `_csrf_token` field.
  - The bootstrap script is an external module, never an inline `<script>` block. The
    browser responses carry a Content-Security-Policy that permits scripts only from this
    origin and forbids inline script, so inlining anything here would be blocked by the
    browser rather than merely frowned upon.
  - The script is served as a plain ES module from the static assets directory and imports
    the framework JavaScript from same-origin vendor paths. There is no bundler in this
    project; editing that file is the whole client build.

  The rendered page must stay free of stored content: it is a shell, and everything a curator
  reads arrives through the LiveView that renders inside it.
  """
  attr :inner_content, :any, required: true

  def root(assigns) do
    ~H"""
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>Cartulary governance</title>
      </head>
      <body>
        {@inner_content}
        <script type="module" src="/assets/governance.js"></script>
      </body>
    </html>
    """
  end
end
