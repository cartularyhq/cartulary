# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Eval.ScorerTest do
  @moduledoc """
  Unit tests for the deterministic, model-free benchmark scorer.

  The scorer answers three separate questions about one system response, and
  the tests below keep them separate:

  1. **Was it right?** Exact match, substring containment, or a token-overlap
     F-measure at or above 0.5 all count as correct. For a question whose
     expected behaviour is to decline, correctness means having abstained —
     text overlap is irrelevant and would reward a confident wrong answer.
  2. **Did it cite the right support?** Measured against the evidence the
     benchmark labelled, independently of whether the prose was right. A
     lucky-guess answer with no supporting citation is visible here.
  3. **How grounded was it?** A lexical stand-in for the retrieval-quality
     triad: answer-versus-context, question-versus-context, and
     question-versus-answer overlap.

  Everything is computed with string arithmetic and no model call. That is the
  point: these are the reproducible numbers a release is checked against, so
  they must give the same result on any machine, offline, at no cost, and
  without a judge model's run-to-run variation. A model-graded judge may be
  reported alongside them under its own separately identified fields, but must
  never replace them.

  The summary side is equally load-bearing. Results are aggregated overall, by
  category, and by context-length bucket, and the last of those is how quality
  loss at longer context is tracked.
  """

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

    # Third argument is what the system actually cited: one of the two labelled
    # evidence turns.
    score = Scorer.score_question(question, result, ["D2:4"])

    # The answer is a full sentence, so it is not an exact match; it wins on
    # containment of the expected phrase instead.
    assert score["correct"]
    assert score["contains_expected"]

    # Hit means "at least one labelled reference was cited". Recall is the
    # fraction of *labelled* references that were cited: one of two, so 0.5.
    # Dividing by the count of cited refs instead would report a perfect 1.0
    # here and hide the missed second piece of evidence entirely.
    assert score["citation_hit"]
    assert score["citation_recall"] == 0.5

    assert is_number(score["groundedness"])
    assert is_number(score["context_relevance"])
    assert is_number(score["answer_relevance"])

    # Every scored row is stamped with the method that produced its triad
    # numbers, so a reader can never mistake lexical proxies for model-judged
    # ones. The embedded "f11-1" is the identity of the evaluation report
    # schema; changing this string is a report-schema transition that obliges a
    # changelog entry and refreshed report provenance, not a free rename.
    assert score["rag_triad_method"] == "deterministic-lexical-f11-1"
  end

  # Declining is the correct behaviour for an unanswerable question, so it has
  # to score as correct. Note the two independent routes to `abstained`: the
  # runner can set the flag explicitly, and a reply that reads as a
  # "not known" phrase is also treated as an abstention, which stops a system
  # from failing the check merely because it phrased its refusal in prose.
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

    # Correct despite "not known" having almost no token overlap with the
    # expected string: the abstention expectation replaces the text check
    # rather than being combined with it.
    assert score["correct"]
    assert score["abstained"]
  end

  # Two identical questions answered at different context lengths: right at
  # 128K, wrong at 1M. That is exactly the shape the degradation curve exists
  # to expose, so the fixture is built to make the buckets differ.
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

    # One of two correct.
    assert summary["overall"]["accuracy"] == 0.5

    # Category grouping ignores scale, so both rows land in one bucket.
    assert summary["by_category"]["Temporal Reasoning"]["questions"] == 2

    # The degradation curve splits the same rows the other way, by context
    # length, and it counts only rows whose benchmark is "beam". An averaged
    # single figure would hide the collapse between these two buckets, which is
    # the one thing this curve exists to make visible.
    assert summary["beam_degradation_curve"]["128K"]["accuracy"] == 1.0
    assert summary["beam_degradation_curve"]["1M"]["accuracy"] == 0.0
  end
end
