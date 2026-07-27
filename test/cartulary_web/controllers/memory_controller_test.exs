# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.MemoryControllerTest do
  use CartularyWeb.ConnCase, async: false

  alias Cartulary.Memory

  setup do
    original_api_key = System.get_env("OPENROUTER_API_KEY")
    original_models = Application.fetch_env!(:cartulary, :models)

    System.delete_env("OPENROUTER_API_KEY")
    Application.put_env(:cartulary, :models, Keyword.put(original_models, :api_key, nil))

    on_exit(fn ->
      if original_api_key do
        System.put_env("OPENROUTER_API_KEY", original_api_key)
      else
        System.delete_env("OPENROUTER_API_KEY")
      end

      Application.put_env(:cartulary, :models, original_models)
    end)

    :ok
  end

  test "GET /api/health freezes the POC health contract", %{conn: conn} do
    conn = get(conn, ~p"/api/health")

    assert %{"status" => "ok", "app" => "cartulary", "version" => "poc-0"} =
             json_response(conn, 200)

    assert_trace_id(conn)
  end

  test "POST /api/v1/ingest freezes raw ingest and extraction contract", %{conn: conn} do
    conn =
      conn
      |> with_account("http-ingest")
      |> post(~p"/api/v1/ingest", ingest_attrs("ingest-session", "/contract/http/ingest"))

    assert %{
             "data" => %{
               "content" => "Avery prefers concise weekly release summaries.",
               "knowledge" => [
                 %{
                   "statement" => "Avery prefers concise weekly release summaries.",
                   "pipeline_version" => "poc-0"
                 }
               ]
             }
           } = json_response(conn, 200)

    assert_trace_id(conn)
  end

  test "POST /api/v1/search freezes scoped retrieval contract", %{conn: conn} do
    seed_memory!("http-search", "/contract/http/search")

    conn =
      conn
      |> with_account("http-search")
      |> post(~p"/api/v1/search", %{
        "scope_path" => "/contract/http/search",
        "query" => "release summaries"
      })

    assert %{
             "data" => %{
               "profile" => "balanced",
               "profile_version" => "poc-0",
               "dropped_strategies" => [],
               "candidates" => [%{"statement" => statement} | _]
             }
           } = json_response(conn, 200)

    assert statement =~ "concise weekly release summaries"
    assert_trace_id(conn)
  end

  test "POST /api/v1/ask freezes grounded fallback answer contract", %{conn: conn} do
    seed_memory!("http-ask", "/contract/http/ask")

    conn =
      conn
      |> with_account("http-ask")
      |> post(~p"/api/v1/ask", %{
        "scope_path" => "/contract/http/ask",
        "question" => "What kind of release summaries does Avery prefer?"
      })

    assert %{
             "data" => %{
               "profile" => "thorough",
               "profile_version" => "poc-0",
               "answer" => answer,
               "abstained" => false,
               "citations" => [_ | _]
             }
           } = json_response(conn, 200)

    assert answer =~ "concise weekly release summaries"
    assert_trace_id(conn)
  end

  test "POST /api/v1/context freezes reasoning-free context contract", %{conn: conn} do
    seed_memory!("http-context", "/contract/http/context")

    conn =
      conn
      |> with_account("http-context")
      |> post(~p"/api/v1/context", %{"scope_path" => "/contract/http/context"})

    assert %{
             "data" => %{
               "profile_version" => "poc-0",
               "session_summary" => nil,
               "scope_cards" => [],
               "peer_profile" => [],
               "knowledge" => [%{"statement" => statement} | _]
             }
           } = json_response(conn, 200)

    assert statement =~ "concise weekly release summaries"
    assert_trace_id(conn)
  end

  test "GET /api/v1/knowledge freezes structured knowledge reads", %{conn: conn} do
    seed_memory!("http-knowledge", "/contract/http/knowledge")

    conn =
      conn
      |> with_account("http-knowledge")
      |> get(~p"/api/v1/knowledge?scope_path=/contract/http/knowledge")

    assert %{
             "data" => [
               %{
                 "statement" => "Avery prefers concise weekly release summaries.",
                 "state" => "active",
                 "scope_path" => "/contract/http/knowledge"
               }
               | _
             ]
           } = json_response(conn, 200)

    assert_trace_id(conn)
  end

  test "caller Account header overrides body Account data", %{conn: conn} do
    conn =
      conn
      |> with_account("caller-account")
      |> post(
        ~p"/api/v1/ingest",
        ingest_attrs("account-session", "/contract/http/account")
        |> Map.put("account_key", "body-selected-account")
      )

    assert %{"data" => %{"knowledge" => [_ | _]}} = json_response(conn, 200)

    assert %{rows: [["caller-account"]]} =
             Ecto.Adapters.SQL.query!(
               Cartulary.Repo,
               """
               SELECT account.key
               FROM accounts AS account
               WHERE account.key IN ('caller-account', 'body-selected-account')
               ORDER BY account.key
               """
             )
  end

  test "agents have no direct knowledge-write route", %{conn: conn} do
    refute Enum.any?(CartularyWeb.Router.__routes__(), fn route ->
             route.verb == :post and route.path == "/api/v1/knowledge"
           end)

    conn =
      conn
      |> with_account("http-direct-write")
      |> post("/api/v1/knowledge", %{
        "statement" => "An agent tried to write this as knowledge.",
        "state" => "active"
      })

    assert json_response(conn, 404)

    assert %{rows: []} =
             Ecto.Adapters.SQL.query!(
               Cartulary.Repo,
               """
               SELECT id
               FROM knowledge_items
               WHERE statement = 'An agent tried to write this as knowledge.'
               """
             )
  end

  defp seed_memory!(account_key, scope_path) do
    assert {:ok, _message} =
             Memory.ingest_message(
               ingest_attrs("#{account_key}-session", scope_path)
               |> Map.put("account_key", account_key)
             )
  end

  defp ingest_attrs(session_id, scope_path) do
    %{
      "session_id" => session_id,
      "scope_path" => scope_path,
      "peer_key" => "agent-1",
      "role" => "user",
      "content" => "Avery prefers concise weekly release summaries."
    }
  end

  defp with_account(conn, account_key) do
    put_req_header(conn, "x-cartulary-account-key", account_key)
  end

  defp assert_trace_id(conn) do
    assert [trace_id] = get_resp_header(conn, "x-trace-id")
    assert trace_id =~ ~r/\A[0-9a-f]{32}\z/
  end
end
