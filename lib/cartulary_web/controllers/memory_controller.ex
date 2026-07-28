# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.MemoryController do
  use CartularyWeb, :controller

  alias Cartulary.Memory

  def health(conn, _params) do
    json(conn, %{status: "ok", app: "cartulary", version: "f5-1"})
  end

  def ingest(conn, params) do
    {:ok, message} =
      params
      |> Memory.ingest_message(conn.assigns.current_actor)

    json(conn, %{data: message})
  end

  def search(conn, params) do
    result =
      params
      |> Memory.search(conn.assigns.current_actor)

    json(conn, %{data: result})
  end

  def ask(conn, params) do
    result =
      params
      |> Memory.ask(conn.assigns.current_actor)

    json(conn, %{data: result})
  end

  def context(conn, params) do
    result =
      params
      |> Memory.get_context(conn.assigns.current_actor)

    json(conn, %{data: result})
  end

  def readiness(conn, params) do
    result =
      params
      |> Memory.check_readiness(conn.assigns.current_actor)

    json(conn, %{data: result})
  end

  def knowledge(conn, params) do
    result =
      params
      |> Memory.query_knowledge(conn.assigns.current_actor)

    json(conn, %{data: result})
  end
end
