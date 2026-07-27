# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Eval.AdapterTest do
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
    assert Enum.map(case.messages, & &1.id) == ["D1:1", "D1:2"]
    assert hd(case.questions).evidence_refs == ["D1:1"]
    assert hd(case.questions).category == "1"
  end

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
    assert hd(case.messages).id == "s1:1"
    assert question.category == "abstention"
    assert question.abstention_expected
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
    assert case.scale == "128K"
    assert hd(case.messages).id == "t1"
    assert hd(case.questions).category == "Instruction Following"
  end
end
