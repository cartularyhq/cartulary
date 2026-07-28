# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.ConnCase do
  @moduledoc """
  ExUnit case template for tests that drive the HTTP surface.

  No web server listens during the suite. `Phoenix.ConnTest` dispatches the
  request through the endpoint and the router in the test process itself, so a
  test exercises the real plug pipeline, the real controllers, and the real
  authentication plugs without a socket.

  Each test gets a `:conn` in its context: a bare request struct with no headers,
  no session, and no identity. Database access is set up by delegating to the
  data case template, so an endpoint test runs inside the same rolled-back SQL
  sandbox transaction as a plain data test, and rows written by the request
  disappear when the test ends.

  ## The connection is deliberately anonymous

  Nothing here logs anyone in, and nothing assigns an Account. The server derives
  the Account from the credential presented on the request, never from a request
  parameter or a test-set assign, so a test that wants an authenticated caller
  must attach a real credential header to the `conn` the same way a client would.
  Faking authentication by assigning an actor onto the `conn` would bypass the
  code path that enforces cross-Account isolation and would make the test prove
  nothing about it.

  ## Async

  `use CartularyWeb.ConnCase, async: true` is safe only while the whole request
  is served in the test process and no work escapes to another process. As soon
  as a test drains Oban, waits on a background job, or exercises anything that
  fans out to tasks, it must drop `async: true` so the sandbox connection is
  shared with those processes.
  """

  use ExUnit.CaseTemplate

  # Injected into every module that does `use CartularyWeb.ConnCase`.
  using do
    quote do
      # Phoenix.ConnTest request macros such as get/post/delete read @endpoint
      # from the calling module, so this attribute is what makes request calls
      # resolve at all. Removing it breaks every request helper in the module.
      @endpoint CartularyWeb.Endpoint

      use CartularyWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import CartularyWeb.ConnCase
    end
  end

  setup tags do
    # Delegates to the data case template rather than duplicating the checkout,
    # so endpoint tests and data tests get identical sandbox and rollback rules.
    Cartulary.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
