# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.AskGroundedAbstentionTest do
  @moduledoc """
  Pins the three grounded outcomes of `Memory.ask/2` and its MCP wrapper.

  A conclusive answer is cited and not abstained; a supported but inconclusive
  answer is cited and abstained; an answer with no surviving retrieved citation
  is replaced by the empty `not known` abstention. The tests use an offline
  provider whose invented ids exercise the same citation intersection used in
  production, and run synchronously because provider selection is node-global.
  """

  use Cartulary.DataCase, async: false

  alias Cartulary.DataLayer
  alias Cartulary.Governance.Actions.McpRead
  alias Cartulary.Governance.Engine, as: GovernanceEngine
  alias Cartulary.Identity
  alias Cartulary.Knowledge.KnowledgeItem
  alias Cartulary.Memory
  alias Cartulary.Model.GroundedAnswerProvider

  require Ash.Query

  @supported_answer "The recorded statements do not establish this, but they support a preference for concise weekly release summaries."

  setup do
    original_provider = Application.get_env(:cartulary, :model_provider)

    on_exit(fn ->
      GroundedAnswerProvider.stop()

      if original_provider do
        Application.put_env(:cartulary, :model_provider, original_provider)
      else
        Application.delete_env(:cartulary, :model_provider)
      end
    end)

    :ok
  end

  test "preserves cited answer text when the model marks the conclusion inconclusive" do
    bootstrap = bootstrap_human!("supported")
    {knowledge_id, scope_path, _session_id} = seed_memory!(bootstrap.actor, "supported")
    {:ok, actor} = Identity.authenticate_bearer(bootstrap.token)
    use_answer_mode!(:grounded_abstention)

    result = ask(actor, scope_path)

    assert result["answer"] == @supported_answer
    assert result["citations"] == [knowledge_id]
    assert result["abstained"]

    assert [prompt] = GroundedAnswerProvider.prompts()

    assert prompt =~
             "If the statements support a conclusion but do not establish it, return one sentence"

    assert prompt =~
             "Keep the qualifier and supported inference in that one sentence, and cite every statement the inference rests on."
  end

  test "strips invented citations and falls back only when none survive" do
    bootstrap = bootstrap_human!("intersection")
    {knowledge_id, scope_path, _session_id} = seed_memory!(bootstrap.actor, "intersection")
    {:ok, actor} = Identity.authenticate_bearer(bootstrap.token)
    use_answer_mode!(:grounded_abstention_with_invented_citation)

    partially_grounded = ask(actor, scope_path)

    assert partially_grounded["answer"] == @supported_answer
    assert partially_grounded["citations"] == [knowledge_id]
    assert partially_grounded["abstained"]

    # Rearming replaces the fixture response and clears its prompt log. This
    # time every citation is invented and the provider claims a conclusion;
    # empty grounding evidence still wins over that claim.
    use_answer_mode!(:unsupported_assertion)

    assert %{
             "answer" => "not known",
             "citations" => [],
             "abstained" => true
           } = ask(actor, scope_path)
  end

  test "does not call the dialectic model when retrieval returns no candidates" do
    bootstrap = bootstrap_human!("empty")
    scope_path = "/ask-grounding/empty"

    assert {:ok, _message} =
             Memory.ingest_message(
               %{
                 "session_id" => "ask-empty-session",
                 "scope_path" => scope_path,
                 "peer_key" => "ask-empty-peer",
                 "role" => "user",
                 "content" => "This raw observation has not been extracted.",
                 "sync_extract" => false
               },
               bootstrap.actor
             )

    {:ok, actor} = Identity.authenticate_bearer(bootstrap.token)
    use_answer_mode!(:grounded_abstention)

    assert %{
             "answer" => "not known",
             "citations" => [],
             "abstained" => true
           } = ask(actor, scope_path)

    assert GroundedAnswerProvider.prompts() == []
  end

  test "MCP ask preserves the cited abstention response shape" do
    bootstrap = bootstrap_human!("mcp")
    {knowledge_id, scope_path, session_id} = seed_memory!(bootstrap.actor, "mcp")
    {:ok, actor} = Identity.authenticate_bearer(bootstrap.token)
    use_answer_mode!(:grounded_abstention)

    input = %{
      arguments: %{
        session_id: session_id,
        scope_path: scope_path,
        question:
          "Does the record establish that Avery prefers concise weekly release summaries?",
        profile: "balanced"
      }
    }

    assert {:ok, result} = McpRead.run(input, [operation: :ask], %{actor: actor})
    assert result["answer"] == @supported_answer
    assert result["citations"] == [knowledge_id]
    assert result["abstained"]
  end

  defp bootstrap_human!(suffix) do
    Identity.bootstrap_human(%{
      email: "ask-#{suffix}@example.test",
      name: "Ask #{suffix}",
      password: "correct horse battery staple"
    })
  end

  defp seed_memory!(actor, suffix) do
    scope_path = "/ask-grounding/#{suffix}"
    session_id = "ask-#{suffix}-session"

    assert {:ok, message} =
             Memory.ingest_message(
               %{
                 "session_id" => session_id,
                 "scope_path" => scope_path,
                 "peer_key" => "ask-#{suffix}-peer",
                 "role" => "user",
                 "content" => "Avery prefers concise weekly release summaries."
               },
               actor
             )

    knowledge_id = message |> Map.fetch!("knowledge") |> hd() |> Map.fetch!("id")

    # The answering contract is independent of Gate timing. Activate the
    # fixture through the ordinary governance engine so every retrieval profile
    # can see it without relying on provisional subject visibility.
    DataLayer.with_account_id(
      actor.account_id,
      [role: :system, pipeline?: true],
      fn account, pipeline_actor ->
        knowledge =
          KnowledgeItem
          |> Ash.Query.filter(id == ^knowledge_id)
          |> Ash.Query.set_tenant(account.id)
          |> Ash.read_one!(actor: pipeline_actor)

        GovernanceEngine.transition!(
          knowledge,
          pipeline_actor,
          %{state: "active", verification: "auto_verified"},
          reason: "ask_grounding_test_activate",
          channel: "pipeline"
        )
      end
    )

    {knowledge_id, scope_path, session_id}
  end

  defp use_answer_mode!(mode) do
    GroundedAnswerProvider.start!(mode)
    Application.put_env(:cartulary, :model_provider, GroundedAnswerProvider)
  end

  defp ask(actor, scope_path) do
    Memory.ask(
      %{
        "scope_path" => scope_path,
        "question" =>
          "Does the record establish that Avery prefers concise weekly release summaries?",
        "profile" => "balanced",
        "deadline" => "disabled"
      },
      actor
    )
  end
end
