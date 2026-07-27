# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.Layouts do
  @moduledoc false

  use CartularyWeb, :html

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
