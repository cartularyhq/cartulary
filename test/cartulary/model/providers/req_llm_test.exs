# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Model.Providers.ReqLLMTest.StubPlug do
  @moduledoc false
  # Serves one canned OpenAI-shaped chat completion, supplied per test as the
  # `:body` option. It exists so the adapter's handling of a 200 response that
  # carries no usable value can be pinned without a network call and without a
  # recorded cassette. Nothing here inspects the request: the tests are about
  # what the adapter does with a response, not what it sends.

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    if test_pid = Keyword.get(opts, :test_pid) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:req_llm_request, Jason.decode!(body)})
      respond(conn, opts)
    else
      respond(conn, opts)
    end
  end

  defp respond(conn, opts) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(Keyword.fetch!(opts, :body)))
  end
end

defmodule Cartulary.Model.Providers.ReqLLMTest do
  @moduledoc """
  Pins two properties of the HTTP model adapter.

  First, that `reasoning_effort` reaches the underlying `req_llm` library as the
  atom its option schema requires, not the string role configuration stores it
  as. Role options are always string-valued (see `Cartulary.Model.Config.Role`),
  because they must stay printable/exportable regardless of source. `req_llm`
  validates `reasoning_effort` with `NimbleOptions` against a fixed atom enum
  and rejects a string outright. Every call that reaches this option must
  therefore convert it before it leaves the adapter; a regression here fails
  every single generation call for any role that sets it, which is exactly
  what shipped in `a566d30` before this file existed.

  Second, that a call which completes with HTTP 200 but carries no usable value
  is named for *why* it is unusable. An aggregator can answer 200 with a choice
  whose finish reason is `error` (its upstream failed mid-generation),
  `length` (the answer was cut off before the tool arguments closed), or
  `content_filter` (the answer was withheld). Those are three different
  operator actions — wait for the retry, raise `CARTULARY_MODEL_MAX_TOKENS`,
  change the input or the model — and collapsing them into one
  `missing_structured_object` leaves an operator reading a trace with no way to
  tell them apart. The error atom is what reaches the usage ledger and the span
  as its error class, so it is the only diagnostic an operator gets.
  """

  use ExUnit.Case, async: true

  alias Cartulary.Model.Config.Role
  alias Cartulary.Model.Provider.Result
  alias Cartulary.Model.Providers.ReqLLM, as: Adapter
  alias Cartulary.Model.Providers.ReqLLMTest.StubPlug

  # Named rather than reused from configuration so the stub server is reached
  # with a credential that exists only for the duration of these tests.
  @key_variable "CARTULARY_TEST_REQ_LLM_KEY"

  # The smallest schema the adapter will forward. Its shape is irrelevant to
  # these tests: every stubbed response is missing its value regardless.
  @schema %{
    "type" => "object",
    "properties" => %{"ok" => %{"type" => "boolean"}},
    "required" => ["ok"]
  }

  @messages [%{role: "user", content: "hi"}]

  setup do
    System.put_env(@key_variable, "test-key")
    on_exit(fn -> System.delete_env(@key_variable) end)
    :ok
  end

  defp role(options) do
    %Role{
      role: :ingest_extractor,
      provider: "openrouter",
      model: "openai/gpt-oss-120b",
      model_version: "unversioned",
      prompt_version: "1",
      pipeline_version: "f5-1",
      config_version: 1,
      options: options
    }
  end

  # Starts a stub endpoint on an ephemeral port and returns a role pointed at
  # it. Port 0 lets the OS pick, so these tests stay async-safe; the bound port
  # is read back from the listener rather than guessed.
  defp stubbed_role(body, plug_opts \\ []) do
    pid =
      start_supervised!(
        {Bandit,
         plug: {StubPlug, Keyword.merge([body: body], plug_opts)},
         port: 0,
         scheme: :http,
         startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)

    role(%{
      "base_url" => "http://127.0.0.1:#{port}",
      "api_key_ref" => "env:#{@key_variable}"
    })
  end

  # One OpenAI-shaped completion. Only the finish reason and the message vary
  # across these tests; everything else is filler the decoder needs present.
  defp completion(finish_reason, message) do
    %{
      "id" => "gen-stub",
      "object" => "chat.completion",
      "created" => 1_700_000_000,
      "model" => "openai/gpt-oss-120b",
      "choices" => [%{"index" => 0, "finish_reason" => finish_reason, "message" => message}],
      "usage" => %{"prompt_tokens" => 12, "completion_tokens" => 0, "total_tokens" => 12}
    }
  end

  defp silent_assistant, do: %{"role" => "assistant", "content" => ""}

  test "a string reasoning_effort from configuration does not fail NimbleOptions validation" do
    config =
      stubbed_role(completion("stop", %{"role" => "assistant", "content" => "hello"}))
      |> update_in([Access.key!(:options)], &Map.put(&1, "reasoning_effort", "low"))

    assert {:ok, %Result{value: "hello"}} =
             Adapter.chat(config, [%{role: "user", content: "hi"}], [])
  end

  test "transport timeout defaults use ReqLLM's req_http_options channel" do
    config =
      stubbed_role(completion("stop", %{"role" => "assistant", "content" => "hello"}))
      |> update_in([Access.key!(:options)], fn options ->
        Map.merge(options, %{"request_timeout" => 300_000, "pool_timeout" => 120_000})
      end)

    assert {:ok, %Result{value: "hello"}} = Adapter.chat(config, @messages, [])
  end

  describe "structured/4 on a 200 response with no object" do
    test "OpenRouter structured generation uses its native JSON-schema response path" do
      config =
        stubbed_role(
          completion("stop", %{"role" => "assistant", "content" => ~s({"ok":true})}),
          test_pid: self()
        )

      assert {:ok, %Result{value: %{"ok" => true}}} =
               Adapter.structured(config, @messages, @schema, [])

      assert_receive {:req_llm_request, request}

      assert %{"type" => "json_schema", "json_schema" => %{"strict" => true}} =
               request["response_format"]

      refute Map.has_key?(request, "tools")
      refute Map.has_key?(request, "tool_choice")
    end

    test "an upstream failure is named as one, not as missing output" do
      config = stubbed_role(completion("error", silent_assistant()))

      # Retrying this exact call is the right response, and the job does retry.
      # The name is what tells an operator that, rather than sending them to
      # look for a prompt or schema problem that does not exist.
      assert {:error, :provider_upstream_error} =
               Adapter.structured(config, @messages, @schema, [])
    end

    test "a truncated answer is named as one, because retrying will not fix it" do
      config = stubbed_role(completion("length", silent_assistant()))

      # This one repeats identically on every retry until the output cap is
      # raised, so it must not look like a transient failure.
      assert {:error, :provider_output_truncated} =
               Adapter.structured(config, @messages, @schema, [])
    end

    test "a withheld answer is named as one" do
      config = stubbed_role(completion("content_filter", silent_assistant()))

      assert {:error, :provider_content_filtered} =
               Adapter.structured(config, @messages, @schema, [])
    end

    test "a model that answers in prose instead of calling the tool keeps the original name" do
      config =
        stubbed_role(
          completion("stop", %{"role" => "assistant", "content" => "Here is my answer instead."})
        )

      assert {:error, :missing_structured_object} =
               Adapter.structured(config, @messages, @schema, [])
    end
  end

  describe "chat/3 on a 200 response with no text" do
    test "an upstream failure is named as one" do
      config = stubbed_role(completion("error", silent_assistant()))

      # A blank completion is not an answer. Returning `{:ok, ""}` here would
      # hand an empty string to a caller that is about to persist or present
      # it, so an unusable response stays an error on this path too.
      assert {:error, :provider_upstream_error} = Adapter.chat(config, @messages, [])
    end

    test "a truncated answer is named as one" do
      config = stubbed_role(completion("length", silent_assistant()))

      assert {:error, :provider_output_truncated} = Adapter.chat(config, @messages, [])
    end

    test "an ordinary empty completion keeps the original name" do
      config = stubbed_role(completion("stop", silent_assistant()))

      assert {:error, :missing_text_response} = Adapter.chat(config, @messages, [])
    end

    test "real text is returned unchanged" do
      config =
        stubbed_role(completion("stop", %{"role" => "assistant", "content" => "an answer"}))

      assert {:ok, %{value: "an answer"}} = Adapter.chat(config, @messages, [])
    end
  end
end
