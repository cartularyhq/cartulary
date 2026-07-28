# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Eval.AdapterTest do
  @moduledoc """
  Unit tests for the benchmark fixture normalizer.

  Public memory benchmarks each ship their own JSON dialect: one names a turn
  `dia_id`, another buries turns inside per-question "haystack" sessions, a
  third calls them probing questions on a chat. The adapter folds all of them
  into a single internal shape — a dataset holding cases, each case holding
  `messages` and `questions` — so the eval harness has exactly one ingest,
  answer, and scoring path regardless of which benchmark is running.

  Each test below pins one source dialect. What they really guard is the set of
  derivation decisions the scorer later depends on:

  - **Message ids.** A question's evidence references name turns by the
    upstream id. If normalization invented positional ids instead, citation
    recall would score zero against otherwise correct retrieval.
  - **Evidence granularity.** Turn-level benchmarks label the exact turn;
    session-level ones only label which session held the answer. The scorer
    must know which it is being handed.
  - **Abstention expectation.** For questions whose correct answer is "the
    conversation does not say", correctness means abstaining, not overlapping
    text. Detecting that from upstream conventions happens here, once.
  - **Scale.** The context-length bucket a case belongs to is what the
    degradation curve is grouped by.

  These are silent-drift hazards: a change here moves published benchmark
  numbers without a single line of the scorer changing, and the new numbers
  are no longer comparable with the old ones.
  """

  use ExUnit.Case, async: true

  alias Cartulary.Eval.Adapter

  test "normalizes LoCoMo sessions and turn-level QA evidence" do
    dataset =
      Adapter.normalize(
        [
          %{
            "sample_id" => "locomo_1",
            "conversation" => %{
              "speaker_a" => "Alice",
              "speaker_b" => "Bob",
              "session_1_date_time" => "10:00 am on 1 January, 2024",
              "session_1" => [
                %{"speaker" => "Alice", "dia_id" => "D1:1", "text" => "I prefer short notes."},
                %{"speaker" => "Bob", "dia_id" => "D1:2", "text" => "I will remember that."}
              ]
            },
            "qa" => [
              %{
                "question" => "What does Alice prefer?",
                "answer" => "short notes",
                "evidence" => ["D1:1"],
                "category" => 1
              }
            ]
          }
        ],
        benchmark: "locomo"
      )

    [case] = dataset.cases
    assert dataset.benchmark == "locomo"

    # Message ids are the upstream `dia_id` strings, verbatim and in session
    # order. The QA entries reference turns by exactly these strings, so
    # renumbering them positionally would break every evidence match.
    assert Enum.map(case.messages, & &1.id) == ["D1:1", "D1:2"]
    assert hd(case.questions).evidence_refs == ["D1:1"]

    # Upstream categories are integers; they are stringified so that grouping a
    # summary by category never has to deal with two key types for one bucket.
    assert hd(case.questions).category == "1"
  end

  # LongMemEval ships one "haystack" of sessions per question. Each instance
  # therefore becomes its own case: the haystack is that question's private
  # corpus, and merging several instances into one case would let a question be
  # answered from another question's sessions.
  test "normalizes LongMemEval as one isolated case per question" do
    dataset =
      Adapter.normalize(
        [
          %{
            "question_id" => "q1_abs",
            "question_type" => "single-session-user",
            "question" => "What is missing?",
            "answer" => "No information available.",
            "haystack_session_ids" => ["s1"],
            "haystack_dates" => ["2024-01-01T00:00:00Z"],
            "haystack_sessions" => [[%{"role" => "user", "content" => "Alice likes tea."}]],
            "answer_session_ids" => ["s1"]
          }
        ],
        benchmark: "longmemeval"
      )

    [case] = dataset.cases
    [question] = case.questions

    assert dataset.benchmark == "longmemeval"

    # Upstream turns are unlabelled, so a stable id is composed from the
    # session id and the 1-based turn position within that session.
    assert hd(case.messages).id == "s1:1"

    # The dataset marks its unanswerable questions only by a "_abs" suffix on
    # the question id. That convention is decoded once, here, into an explicit
    # category and flag; the scorer then judges these questions on whether the
    # system abstained rather than on answer text overlap.
    assert question.category == "abstention"
    assert question.abstention_expected

    # This benchmark labels the answer *session*, never the answer turn, so
    # citation credit has to be evaluated at session granularity. Claiming
    # "turn" here would fail every citation for correct retrieval.
    assert question.evidence_granularity == "session"
  end

  test "normalizes BEAM-style conversations and probing questions" do
    dataset =
      Adapter.normalize(
        %{
          "chats" => [
            %{
              "chat_id" => "beam-a",
              "chat_size" => "128K",
              "messages" => [
                %{"turn_id" => "t1", "role" => "user", "content" => "Use metric units."}
              ],
              "probing_questions" => [
                %{
                  "question_id" => "pq1",
                  "question" => "Which units should be used?",
                  "answer" => "metric units",
                  "ability" => "Instruction Following",
                  "evidence_turns" => ["t1"]
                }
              ]
            }
          ]
        },
        benchmark: "beam"
      )

    [case] = dataset.cases

    # `scale` is the declared context length of the chat. It is the bucket key
    # for the degradation curve, which is how quality loss at longer context is
    # tracked, so it must survive normalization as the upstream label.
    assert case.scale == "128K"
    assert hd(case.messages).id == "t1"

    # This benchmark calls its question class an "ability"; it is mapped onto
    # the same `category` field the other benchmarks use so one summary
    # grouping works across all of them.
    assert hd(case.questions).category == "Instruction Following"
  end

  # The only case that goes through `load!/2` rather than `normalize/2`, so it
  # also covers reading the file from disk and digesting its bytes.
  test "normalizes ConvoMem conversations, categories, evidence, and abstention" do
    dataset =
      Adapter.load!("test/fixtures/eval/convomem-minimal.json", benchmark: "convomem")

    [preference, abstention] = dataset.cases

    assert dataset.benchmark == "convomem"
    assert dataset.source_format == "convomem"

    # 64 characters is a SHA-256 digest in lowercase hex. Every dataset carries
    # one so that a published result names the exact bytes it was measured
    # over: editing a fixture changes the digest and makes the difference
    # visible instead of silently re-baselining a score.
    assert byte_size(dataset.dataset_sha256) == 64

    assert hd(preference.messages).id == "cm-pref-1"
    assert hd(preference.questions).evidence_refs == ["cm-pref-1"]

    # The second fixture row asks something its conversation never mentions.
    # Either signal marks it: an "abstention" category or an explicit flag on
    # the row. Correctness for it means declining to answer.
    assert hd(abstention.questions).abstention_expected
  end
end
