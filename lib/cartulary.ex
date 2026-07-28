# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary do
  @moduledoc """
  Root namespace of the Cartulary OTP application. It intentionally defines nothing.

  Cartulary is a memory system: agents and people submit raw observations, an
  extraction pipeline turns them into candidate statements, governance decides
  which of those may become durable knowledge, and retrieval serves the
  governed result back. Nothing in that chain lives here — this module exists
  only so the application has a top-level namespace, and adding behaviour to it
  would put logic in the one place no reader thinks to look.

  The entry points a newcomer usually wants are:

  * `Cartulary.Application` — the supervision tree and boot order.
  * `Cartulary.Memory` — the in-process facade the HTTP surface and the
    evaluation harness call: ingest, search, ask, context, readiness.
  * `Cartulary.DataLayer` — the only sanctioned way to open an Account-scoped
    database transaction.
  * `CartularyWeb` — the Phoenix surface.
  """
end
