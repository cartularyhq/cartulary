# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Eval.ScorerTest do
  use ExUnit.Case, async: true

  alias Cartulary.Eval.Scorer

  test "scores expected answer overlap and citation recall" do
    question = %{
      expected: ["concise status updates"],
      evidence_refs: ["D1:1", "D2:4"],
      evidence_granularity: "turn",
      abstention_expected: false
    }

    result = %{"answer" => "Alice prefers concise status updates.", "abstained" => false}

    score = Scorer.score_question(question, result, ["D2:4"])

    assert score["correct"]
    assert score["contains_expected"]
    assert score["citation_hit"]
    assert score["citation_recall"] == 0.5
    assert is_number(score["groundedness"])
    assert is_number(score["context_relevance"])
    assert is_number(score["answer_relevance"])
    assert score["rag_triad_method"] == "deterministic-lexical-f11-1"
  end

  test "scores expected abstention" do
    question = %{
      expected: ["No information available."],
      evidence_refs: [],
      abstention_expected: true
    }

    score =
      Scorer.score_question(
        question,
        %{"answer" => "not known", "abstained" => true},
        []
      )

    assert score["correct"]
    assert score["abstained"]
  end

  test "summarizes by category and BEAM scale" do
    results = [
      %{
        "benchmark" => "beam",
        "category" => "Temporal Reasoning",
        "scale" => "128K",
        "correct" => true,
        "contains_expected" => true,
        "token_f1" => 1.0,
        "citation_hit" => true,
        "citation_recall" => 1.0,
        "latency_ms" => 10
      },
      %{
        "benchmark" => "beam",
        "category" => "Temporal Reasoning",
        "scale" => "1M",
        "correct" => false,
        "contains_expected" => false,
        "token_f1" => 0.0,
        "citation_hit" => false,
        "citation_recall" => 0.0,
        "latency_ms" => 30
      }
    ]

    summary = Scorer.summarize(results)

    assert summary["overall"]["accuracy"] == 0.5
    assert summary["by_category"]["Temporal Reasoning"]["questions"] == 2
    assert summary["beam_degradation_curve"]["128K"]["accuracy"] == 1.0
    assert summary["beam_degradation_curve"]["1M"]["accuracy"] == 0.0
  end
end
