# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.ErrorJSONTest do
  @moduledoc """
  Pins the JSON body returned for any failed request.

  This renderer is what an unauthenticated stranger sees when they hit an
  unknown route, are refused, or provoke a crash — no credential is needed to
  reach it. So the body has to stay uninformative: nothing but the standard
  status text for the status code. Anything richer (an exception message,
  changeset internals, a resource or column name, an echoed parameter) would be
  disclosed to whoever can trigger the error, and error paths are the easiest
  thing on a server to trigger deliberately.

  The two cases below are the two ends of that risk. A 404 is trivially
  reachable by guessing paths, and a 500 is the one whose underlying reason is
  genuinely sensitive. Both are asserted to be exactly the generic wording, and
  the assigns map is passed empty to document that this renderer draws nothing
  from the request: an operator recovers the real cause from the server logs,
  correlated by the trace id header that every response carries.

  If a future change makes either body more descriptive, that is a disclosure
  decision, not a formatting change — this test failing is the intended alarm.
  """

  use CartularyWeb.ConnCase, async: true

  test "renders 404" do
    assert CartularyWeb.ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
  end

  # The wording must not hint at what actually failed. It is derived from the
  # template name alone, so it is identical whether the cause was a database
  # outage, a bad query, or a bug in a controller.
  test "renders 500" do
    assert CartularyWeb.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end
end
