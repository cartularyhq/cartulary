# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.SelfGovernanceController do
  use CartularyWeb, :controller

  alias Cartulary.Governance.Engine
  alias Cartulary.Governance.Erasure

  def index(conn, _params) do
    knowledge =
      conn.assigns.current_actor
      |> Engine.self_view()
      |> Enum.map(&public_map/1)

    json(conn, %{data: knowledge})
  end

  def contest(conn, %{"id" => id}) do
    knowledge = Engine.contest(conn.assigns.current_actor, id, "contest")
    json(conn, %{data: public_map(knowledge)})
  end

  def redact(conn, %{"id" => id}) do
    knowledge = Engine.contest(conn.assigns.current_actor, id, "redact")
    json(conn, %{data: public_map(knowledge)})
  end

  def erase(conn, params) do
    mode = Map.get(params, "mode", "proportionate")

    request =
      Erasure.request(conn.assigns.current_actor, conn.assigns.current_actor.peer_id, mode)

    json(conn, %{data: %{id: request.id, mode: request.mode, state: request.state}})
  end

  defp public_map(record) do
    record.__struct__
    |> Ash.Resource.Info.public_attributes()
    |> Map.new(fn attribute -> {attribute.name, Map.get(record, attribute.name)} end)
  end
end
