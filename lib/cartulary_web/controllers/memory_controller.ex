# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.MemoryController do
  use CartularyWeb, :controller

  alias Cartulary.Memory

  def health(conn, _params) do
    json(conn, %{status: "ok", app: "cartulary", version: "poc-0"})
  end

  def ingest(conn, params) do
    {:ok, message} =
      params
      |> with_account(conn)
      |> Memory.ingest_message()

    json(conn, %{data: message})
  end

  def search(conn, params) do
    result =
      params
      |> with_account(conn)
      |> Memory.search()

    json(conn, %{data: result})
  end

  def ask(conn, params) do
    result =
      params
      |> with_account(conn)
      |> Memory.ask()

    json(conn, %{data: result})
  end

  def context(conn, params) do
    result =
      params
      |> with_account(conn)
      |> Memory.get_context()

    json(conn, %{data: result})
  end

  def knowledge(conn, params) do
    result =
      params
      |> with_account(conn)
      |> Memory.query_knowledge()

    json(conn, %{data: result})
  end

  defp with_account(params, conn) do
    account_key =
      conn
      |> get_req_header("x-cartulary-account-key")
      |> List.first()
      |> case do
        nil -> "local-poc"
        value -> value
      end

    Map.put(params, "account_key", account_key)
  end
end
