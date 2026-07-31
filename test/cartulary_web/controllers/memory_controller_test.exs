# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.MemoryControllerTest do
  @moduledoc """
  The frozen behaviour baseline for the JSON HTTP surface.

    Several literals asserted below — `"f5-1"` for the extraction and pipeline
    behaviour, `"f7-1"` for retrieval and context behaviour — are contract identities,
    not the application's semantic version. They tell a client which behaviour it is
    talking to and they do not move when the app version does.
  """

  use CartularyWeb.ConnCase, async: false

  alias Cartulary.Identity
  alias Cartulary.Memory

  setup do
    # Remove any model credential the developer's shell or the loaded config
    # might supply, so nothing below can reach a live endpoint. The test
    # environment already resolves the generation roles to the local
    # deterministic provider at boot; this only makes sure a stray key cannot
    # undo that. Both values are restored on exit so the next test sees the
    # machine it expected.
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

    # Creates the single community Account, its root scope, an administrator
    # peer with a propagating grant at that root, and a sign-in token. Without
    # the root grant the new administrator would be authorized for nothing,
    # because authority over a scope is inherited downward from an ancestor.
    # The token is the credential every authenticated request below presents;
    # the actor is used only for seeding, which goes through the domain rather
    # than HTTP.
    bootstrap =
      Identity.bootstrap_human(%{
        email: "admin@example.test",
        name: "Test Admin",
        password: "correct horse battery staple"
      })

    {:ok, actor: bootstrap.actor, token: bootstrap.token}
  end

  # Deliberately sent without a credential: the liveness probe must answer
  # before any identity exists, so an orchestrator can tell a starting
  # container from a wedged one. It also touches no database, which is why
  # container liveness should point here and readiness elsewhere — wiring
  # liveness to database checks turns a brief database blip into a restart
  # loop.
  test "GET /api/health freezes the POC health contract", %{conn: conn} do
    conn = get(conn, ~p"/api/health")

    # "f5-1" names the extraction and pipeline behaviour this build implements,
    # so a client can discover which extractor it is talking to. It is a
    # contract identity, not the release version, and does not change when the
    # application version does.
    assert %{"status" => "ok", "app" => "cartulary", "version" => "f5-1"} =
             json_response(conn, 200)

    assert_trace_id(conn)
  end

  # The only write path an agent has. Note that the scope path in the body does
  # not exist yet: missing scopes, the session, and their links are created on
  # demand, so a client never has to provision topology before speaking.
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
               # The raw observation is stored verbatim. It is the durable
               # record; everything derived from it can be rebuilt, but this
               # text cannot be re-derived from anything else.
               "content" => "Avery prefers concise weekly release summaries.",
               # Extraction ran inline and returned what it proposed. These
               # items are pipeline output, never caller input: no field in the
               # request body can mint knowledge, and each item still has to
               # pass the governance gate before anyone beyond the submitting
               # peer can see it.
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

  # Ranked retrieval with no answer generation. A scope path selects that scope
  # together with its ancestors, because context flows downward: a child scope
  # sees what its parents know and never the reverse. Account, authorization,
  # lifecycle, and source filtering all happen inside retrieval before any
  # candidate reaches this response, so a caller never post-filters.
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
               # Search defaults to the middle profile; answering defaults to
               # the slower, more thorough one, because an answer justifies
               # more latency than a bare candidate list.
               "profile" => "balanced",
               # "f7-1" names the retrieval and context behaviour a client is
               # written against. Like the other identity strings here it is a
               # contract version, not the release version.
               "profile_version" => "f7-1",
               # Empty means every retrieval strategy finished inside the
               # deadline. A non-empty list is not an error — it is how the
               # response admits that results are partial, which is why the
               # field exists at all.
               "dropped_strategies" => [],
               "candidates" => [%{"statement" => statement} | _]
             }
           } = json_response(conn, 200)

    # Candidates arrive in fused rank order. Each strategy scores in its own
    # space, so re-sorting by a raw per-strategy score compares numbers that
    # are not comparable and silently degrades the ranking.
    assert statement =~ "concise weekly release summaries"
    assert_trace_id(conn)
  end

  # Retrieval plus a grounded answer. With no model credential configured the
  # answer is composed from the retrieved statements themselves, which is why
  # this passes offline; the shape of the response is identical either way.
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
               "profile_version" => "f7-1",
               "answer" => answer,
               # Not abstaining, with at least one citation, is the pair that
               # makes the answer trustworthy: when nothing supports the
               # question the action declines instead of inventing an answer,
               # so `abstained == true` is an ordinary outcome and not a
               # failure a client should retry.
               "abstained" => false,
               "citations" => [_ | _]
             }
           } = json_response(conn, 200)

    assert answer =~ "concise weekly release summaries"
    assert_trace_id(conn)
  end

  # Context assembly is a projection read, never an inference. No generation
  # model is called on this path, which is what keeps it cheap and repeatable;
  # introducing a model call here would turn a lookup into an inference and
  # break that guarantee.
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
               "profile_version" => "f7-1",
               # Absent because nothing has built a projection for this
               # brand-new scope yet. Summaries, scope cards, and peer profiles
               # are derived views over governed knowledge, so before their
               # background rebuild runs they are missing rather than wrong.
               "session_summary" => nil,
               "scope_cards" => [],
               "entity_cards" => [],
               "peer_profile" => [],
               # Reports that the projection was missing and the fastest
               # retrieval profile filled the gap live. Callers need to tell a
               # cached assembly from an improvised one; the improvised path
               # still calls no reasoning model.
               "fast_fallback" => true,
               "knowledge" => [%{"statement" => statement} | _]
             }
           } = json_response(conn, 200)

    assert statement =~ "concise weekly release summaries"
    assert_trace_id(conn)
  end

  # A read-only listing. There is deliberately no POST counterpart; see the
  # route-absence test further down, which enforces that.
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
                 # Not "active": a freshly extracted item is gated, never
                 # auto-promoted. "provisional" means it is usable by the peer
                 # who supplied it while it waits for a decision, and invisible
                 # to everyone else. It appears in this default listing only
                 # because the default view also includes the caller's own
                 # provisional items — asserting "active" here would mean
                 # extraction had started publishing without a gate.
                 "state" => "provisional",
                 # Each row is annotated with the scope it actually lives at,
                 # because a listing spans the requested scope plus every
                 # ancestor it inherits from, and the caller needs to know
                 # which of those a given statement came from.
                 "scope_path" => "/contract/http/knowledge"
               }
               | _
             ]
           } = json_response(conn, 200)

    assert_trace_id(conn)
  end

  # Cross-account isolation is absolute, and it rests on the Account being
  # derived from the verified credential rather than named by the request. This
  # sends both historical ways of naming one — the deprecated header and a body
  # field — with values that match no existing Account. An old client must fail
  # closed into its own Account instead of reaching into, or conjuring,
  # another.
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

    # The request still succeeds; the extra fields are accepted and ignored
    # rather than rejected, so an outdated client keeps working safely.
    assert %{"data" => %{"knowledge" => [_ | _]}} = json_response(conn, 200)

    # Raw SQL on purpose. An Ash read would be filtered to the caller's own
    # Account, which is precisely the filter under test — it could not see a
    # stray Account row even if one had been created. Querying the table
    # directly is the only way to prove that neither supplied key created or
    # selected anything: "local" is the single bootstrapped community Account,
    # and it is the only row that comes back.
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

  # The load-bearing absence. An agent may submit observations and read
  # governed memory, but it must never be able to declare something true: the
  # extraction pipeline is the only writer of knowledge, and what it writes
  # still has to clear a governance decision. Without this test, "no one has
  # added a write route yet" and "adding a write route is forbidden" look
  # identical to anyone reading the router.
  test "agents have no direct knowledge-write route", %{conn: conn, token: token} do
    # Inspecting the compiled route table catches the mistake at its source: a
    # route added here would fail this half even before anyone wrote a handler
    # that persists anything.
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

    # Authenticated and still 404: the credential is valid, so the refusal is
    # the missing route, not a rejected identity.
    assert json_response(conn, 404)

    # The second half, and the one that actually matters. A 404 alone would not
    # rule out some other path having persisted the statement. Reading the
    # table directly, unfiltered by tenancy, proves nothing was written
    # anywhere.
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

  # Seeds one observation through the domain rather than over HTTP. The write
  # path is the same one the ingest route uses, so the seeded knowledge is
  # governed exactly like anything a client submits; going direct simply keeps
  # the retrieval tests from also depending on the ingest route passing.
  defp seed_memory!(actor, key, scope_path) do
    assert {:ok, _message} =
             Memory.ingest_message(ingest_attrs("#{key}-session", scope_path), actor)
  end

  # One shared observation for every test. Each test uses its own scope path so
  # the cases stay isolated, while the identical sentence keeps the expected
  # statement, answer, and citation text the same everywhere.
  defp ingest_attrs(session_id, scope_path) do
    %{
      "session_id" => session_id,
      "scope_path" => scope_path,
      "peer_key" => "agent-1",
      "role" => "user",
      "content" => "Avery prefers concise weekly release summaries."
    }
  end

  # Presents the bearer token. Everything except the probes is rejected with
  # 401 before the controller runs when this is omitted, and the Account and
  # the acting peer are both derived from the credential it carries.
  defp with_identity(conn, token),
    do: put_req_header(conn, "authorization", "Bearer #{token}")

  # Asserted on every route: an operator must be able to lift a correlation id
  # off any response and find the matching log lines. 32 lowercase hex
  # characters is the standard 128-bit trace-id width.
  defp assert_trace_id(conn) do
    assert [trace_id] = get_resp_header(conn, "x-trace-id")
    assert trace_id =~ ~r/\A[0-9a-f]{32}\z/
  end
end
