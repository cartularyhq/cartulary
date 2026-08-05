# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.AskGroundedAbstentionTest do
  @moduledoc """
  Pins the grounded outcomes of `Memory.ask/2` and its MCP wrapper.

  A confident answer is cited and not abstained; a low-confidence answer keeps
  its text and citations but abstains whatever the model claimed; an answer with
  no surviving retrieved citation is replaced by the empty abstention. The
  prompt is also pinned to instruct the model never to refuse, because a refusal
  is what the confidence percentage replaced. The tests use an offline provider
  whose invented ids exercise the same citation intersection used in production,
  and run synchronously because provider selection is node-global.
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
  @inferred_answer "Avery most likely prefers concise weekly release summaries."
  @no_evidence_answer "No memory statements were retrieved for this question."

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
    assert result["answer_confidence"] == 30

    assert [prompt] = GroundedAnswerProvider.prompts()

    assert prompt =~
             "Always give your best answer. Never reply \"not known\", \"unknown\", \"no information available\", or \"cannot answer\""

    assert prompt =~
             "infer the most probable one from the statements, use an explicit likelihood word"

    assert prompt =~
             "Cite every statement your answer rests on, including a low-confidence one."
  end

  test "keeps a confident inference as a conclusion" do
    bootstrap = bootstrap_human!("confident")
    {knowledge_id, scope_path, _session_id} = seed_memory!(bootstrap.actor, "confident")
    {:ok, actor} = Identity.authenticate_bearer(bootstrap.token)
    use_answer_mode!(:confident_inference)

    result = ask(actor, scope_path)

    assert result["answer"] == @inferred_answer
    assert result["citations"] == [knowledge_id]
    assert result["answer_confidence"] == 80
    refute result["abstained"]
  end

  test "abstains on a low-confidence inference while keeping its text and citations" do
    bootstrap = bootstrap_human!("low-confidence")
    {knowledge_id, scope_path, _session_id} = seed_memory!(bootstrap.actor, "low-confidence")
    {:ok, actor} = Identity.authenticate_bearer(bootstrap.token)
    use_answer_mode!(:low_confidence_inference)

    result = ask(actor, scope_path)

    # The fixture claims a conclusion at 20. The answer survives as a lead, the
    # claim does not.
    assert result["answer"] == @inferred_answer
    assert result["citations"] == [knowledge_id]
    assert result["answer_confidence"] == 20
    assert result["abstained"]
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
    # time every citation is invented and the provider claims a conclusion at
    # 90; empty grounding evidence still wins over that claim.
    use_answer_mode!(:unsupported_assertion)

    assert %{
             "answer" => @no_evidence_answer,
             "citations" => [],
             "abstained" => true,
             "answer_confidence" => 0
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
             "answer" => @no_evidence_answer,
             "citations" => [],
             "abstained" => true,
             "answer_confidence" => 0
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
    assert result["answer_confidence"] == 30
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

    assert {:ok, [knowledge]} =
             Memory.extract_message_for_account(message["id"], actor.account_id)

    knowledge_id = knowledge["id"]

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
