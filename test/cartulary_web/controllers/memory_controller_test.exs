# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.MemoryControllerTest do
  use CartularyWeb.ConnCase, async: false

  alias Cartulary.Identity
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

    bootstrap =
      Identity.bootstrap_human(%{
        email: "admin@example.test",
        name: "Test Admin",
        password: "correct horse battery staple"
      })

    {:ok, actor: bootstrap.actor, token: bootstrap.token}
  end

  test "GET /api/health freezes the POC health contract", %{conn: conn} do
    conn = get(conn, ~p"/api/health")

    assert %{"status" => "ok", "app" => "cartulary", "version" => "f5-1"} =
             json_response(conn, 200)

    assert_trace_id(conn)
  end

  test "POST /api/v1/ingest freezes raw ingest and extraction contract", %{
    conn: conn,
    token: token
  } do
    conn =
      conn
      |> with_identity(token)
      |> post(~p"/api/v1/ingest", ingest_attrs("ingest-session", "/contract/http/ingest"))

    assert %{
             "data" => %{
               "content" => "Avery prefers concise weekly release summaries.",
               "knowledge" => [
                 %{
                   "statement" => "Avery prefers concise weekly release summaries.",
                   "pipeline_version" => "f5-1"
                 }
               ]
             }
           } = json_response(conn, 200)

    assert_trace_id(conn)
  end

  test "POST /api/v1/search freezes scoped retrieval contract", %{
    conn: conn,
    actor: actor,
    token: token
  } do
    seed_memory!(actor, "http-search", "/contract/http/search")

    conn =
      conn
      |> with_identity(token)
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

  test "POST /api/v1/ask freezes grounded fallback answer contract", %{
    conn: conn,
    actor: actor,
    token: token
  } do
    seed_memory!(actor, "http-ask", "/contract/http/ask")

    conn =
      conn
      |> with_identity(token)
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

  test "POST /api/v1/context freezes reasoning-free context contract", %{
    conn: conn,
    actor: actor,
    token: token
  } do
    seed_memory!(actor, "http-context", "/contract/http/context")

    conn =
      conn
      |> with_identity(token)
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

  test "GET /api/v1/knowledge freezes structured knowledge reads", %{
    conn: conn,
    actor: actor,
    token: token
  } do
    seed_memory!(actor, "http-knowledge", "/contract/http/knowledge")

    conn =
      conn
      |> with_identity(token)
      |> get(~p"/api/v1/knowledge?scope_path=/contract/http/knowledge")

    assert %{
             "data" => [
               %{
                 "statement" => "Avery prefers concise weekly release summaries.",
                 "state" => "provisional",
                 "scope_path" => "/contract/http/knowledge"
               }
               | _
             ]
           } = json_response(conn, 200)

    assert_trace_id(conn)
  end

  test "authenticated identity overrides deprecated header and body Account data", %{
    conn: conn,
    token: token
  } do
    conn =
      conn
      |> put_req_header("x-cartulary-account-key", "header-selected-account")
      |> with_identity(token)
      |> post(
        ~p"/api/v1/ingest",
        ingest_attrs("account-session", "/contract/http/account")
        |> Map.put("account_key", "body-selected-account")
      )

    assert %{"data" => %{"knowledge" => [_ | _]}} = json_response(conn, 200)

    assert %{rows: [["local"]]} =
             Ecto.Adapters.SQL.query!(
               Cartulary.Repo,
               """
               SELECT account.key
               FROM accounts AS account
               WHERE account.key IN ('local', 'header-selected-account', 'body-selected-account')
               ORDER BY account.key
               """
             )
  end

  test "agents have no direct knowledge-write route", %{conn: conn, token: token} do
    refute Enum.any?(CartularyWeb.Router.__routes__(), fn route ->
             route.verb == :post and route.path == "/api/v1/knowledge"
           end)

    conn =
      conn
      |> with_identity(token)
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

  defp seed_memory!(actor, key, scope_path) do
    assert {:ok, _message} =
             Memory.ingest_message(ingest_attrs("#{key}-session", scope_path), actor)
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

  defp with_identity(conn, token),
    do: put_req_header(conn, "authorization", "Bearer #{token}")

  defp assert_trace_id(conn) do
    assert [trace_id] = get_resp_header(conn, "x-trace-id")
    assert trace_id =~ ~r/\A[0-9a-f]{32}\z/
  end
end
