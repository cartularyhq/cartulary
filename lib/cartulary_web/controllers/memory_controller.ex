# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.MemoryController do
  use CartularyWeb, :controller

  alias Cartulary.Memory
  alias Cartulary.Operations.Health

  def health(conn, _params) do
    json(conn, %{status: "ok", app: "cartulary", version: "f5-1"})
  end

  def ready(conn, _params) do
    result = Health.readiness()
    status = if Health.ready?(result), do: 200, else: 503
    conn |> put_status(status) |> json(result)
  end

  def costs(conn, _params) do
    actor = conn.assigns.current_actor

    if actor.role in [:account_admin, :system] do
      json(conn, %{data: Cartulary.Operations.Metering.summary(actor)})
    else
      conn |> put_status(:forbidden) |> json(%{error: "Forbidden"})
    end
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
