# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Eval.Scorer do
  @moduledoc """
  Deterministic benchmark scoring for Cartulary memory eval runs.

  These scores are not a replacement for the upstream LLM judges. They are the
  reproducible in-repo baseline: exact/contains/token-F1 answer checks,
  abstention checks, and citation/evidence recall.
  """

  @not_known_markers [
    "not known",
    "unknown",
    "not enough information",
    "no information available",
    "i don't know",
    "cannot answer"
  ]

  @doc """
  Scores one answer with deterministic correctness, evidence, RAG-triad proxy,
  and token-efficiency metrics.

  The lexical RAG triad is the deterministic PR/release baseline. Live release
  reports may add a separately identified model judge, but must never replace
  these reproducible measurements.
  """
  def score_question(question, result, cited_refs, opts \\ []) do
    expected = Map.get(question, :expected, [])
    answer = result |> Map.get("answer", "") |> to_string()
    candidates = Map.get(result, "candidates", [])
    abstention_expected? = Map.get(question, :abstention_expected, false)
    abstained? = Map.get(result, "abstained", false) == true or not_known?(answer)
    token_f1 = best_token_f1(answer, expected)
    contains_expected? = contains_expected?(answer, expected)
    exact_match? = exact_match?(answer, expected)
    evidence_refs = Map.get(question, :evidence_refs, [])
    citation = citation_score(evidence_refs, cited_refs)
    triad = rag_triad(Map.get(question, :question, ""), answer, candidates, abstained?)
    efficiency = token_efficiency(answer, candidates, Keyword.get(opts, :full_context_tokens, 0))

    correct? =
      if abstention_expected? do
        abstained?
      else
        exact_match? or contains_expected? or token_f1 >= 0.5
      end

    %{
      "exact_match" => exact_match?,
      "contains_expected" => contains_expected?,
      "token_f1" => token_f1,
      "abstention_expected" => abstention_expected?,
      "abstained" => abstained?,
      "correct" => correct?,
      "citation_hit" => citation.hit?,
      "citation_recall" => citation.recall,
      "groundedness" => triad.groundedness,
      "context_relevance" => triad.context_relevance,
      "answer_relevance" => triad.answer_relevance,
      "rag_triad_method" => "deterministic-lexical-f11-1",
      "context_tokens" => efficiency.context_tokens,
      "answer_tokens" => efficiency.answer_tokens,
      "end_to_end_tokens" => efficiency.end_to_end_tokens,
      "full_context_tokens" => efficiency.full_context_tokens,
      "token_efficiency_ratio" => efficiency.ratio,
      "expected_refs" => evidence_refs,
      "cited_refs" => cited_refs
    }
  end

  def summarize(question_results) do
    %{
      "overall" => aggregate(question_results),
      "by_category" => group_aggregate(question_results, "category"),
      "by_scale" => group_aggregate(question_results, "scale"),
      "beam_degradation_curve" => beam_degradation_curve(question_results)
    }
  end

  defp group_aggregate(results, key) do
    results
    |> Enum.group_by(fn result -> result |> Map.get(key) |> blank_to("uncategorized") end)
    |> Map.new(fn {group, group_results} -> {group, aggregate(group_results)} end)
  end

  defp beam_degradation_curve(results) do
    results
    |> Enum.filter(&(Map.get(&1, "benchmark") == "beam"))
    |> group_aggregate("scale")
  end

  defp aggregate([]) do
    %{
      "questions" => 0,
      "accuracy" => 0.0,
      "mean_token_f1" => 0.0,
      "contains_rate" => 0.0,
      "abstention_accuracy" => nil,
      "citation_hit_rate" => 0.0,
      "mean_citation_recall" => 0.0,
      "mean_groundedness" => 0.0,
      "mean_context_relevance" => 0.0,
      "mean_answer_relevance" => 0.0,
      "mean_end_to_end_tokens" => 0.0,
      "mean_full_context_tokens" => 0.0,
      "mean_token_efficiency_ratio" => 0.0,
      "latency_ms" => latency_summary([])
    }
  end

  defp aggregate(results) do
    abstention_results = Enum.filter(results, &Map.get(&1, "abstention_expected"))

    %{
      "questions" => length(results),
      "accuracy" => ratio(results, &Map.get(&1, "correct")),
      "mean_token_f1" => mean(results, &Map.get(&1, "token_f1")),
      "contains_rate" => ratio(results, &Map.get(&1, "contains_expected")),
      "abstention_accuracy" =>
        if(abstention_results == [],
          do: nil,
          else: ratio(abstention_results, &Map.get(&1, "correct"))
        ),
      "citation_hit_rate" => ratio(results, &Map.get(&1, "citation_hit")),
      "mean_citation_recall" => mean(results, &Map.get(&1, "citation_recall")),
      "mean_groundedness" => mean(results, &Map.get(&1, "groundedness")),
      "mean_context_relevance" => mean(results, &Map.get(&1, "context_relevance")),
      "mean_answer_relevance" => mean(results, &Map.get(&1, "answer_relevance")),
      "mean_end_to_end_tokens" => mean(results, &Map.get(&1, "end_to_end_tokens")),
      "mean_full_context_tokens" => mean(results, &Map.get(&1, "full_context_tokens")),
      "mean_token_efficiency_ratio" => mean(results, &Map.get(&1, "token_efficiency_ratio")),
      "mean_model_groundedness" => optional_mean(results, "model_groundedness"),
      "mean_model_context_relevance" => optional_mean(results, "model_context_relevance"),
      "mean_model_answer_relevance" => optional_mean(results, "model_answer_relevance"),
      "latency_ms" => results |> Enum.map(&Map.get(&1, "latency_ms", 0)) |> latency_summary()
    }
  end

  defp rag_triad(_question, _answer, _candidates, true) do
    %{groundedness: 1.0, context_relevance: 0.0, answer_relevance: 1.0}
  end

  defp rag_triad(question, answer, candidates, false) do
    context =
      candidates
      |> Enum.map_join(" ", fn candidate ->
        Map.get(candidate, "statement") || Map.get(candidate, "content") || ""
      end)

    %{
      groundedness: lexical_f1(answer, context),
      context_relevance: lexical_f1(question, context),
      answer_relevance: lexical_f1(question, answer)
    }
  end

  defp token_efficiency(answer, candidates, full_context_tokens) do
    context_tokens =
      candidates
      |> Enum.map(fn candidate ->
        candidate
        |> then(&(Map.get(&1, "statement") || Map.get(&1, "content") || ""))
        |> token_count()
      end)
      |> Enum.sum()

    answer_tokens = token_count(answer)
    end_to_end_tokens = context_tokens + answer_tokens

    %{
      context_tokens: context_tokens,
      answer_tokens: answer_tokens,
      end_to_end_tokens: end_to_end_tokens,
      full_context_tokens: full_context_tokens,
      ratio:
        if(full_context_tokens > 0,
          do: end_to_end_tokens / full_context_tokens,
          else: 0.0
        )
    }
  end

  defp lexical_f1(left, right), do: token_f1(token_counts(left), token_counts(right))

  defp token_count(value) do
    value
    |> token_counts()
    |> Map.values()
    |> Enum.sum()
  end

  defp citation_score([], _cited_refs), do: %{hit?: false, recall: 0.0}

  defp citation_score(evidence_refs, cited_refs) do
    expected = MapSet.new(evidence_refs)
    cited = MapSet.new(cited_refs)
    overlap = expected |> MapSet.intersection(cited) |> MapSet.size()

    %{hit?: overlap > 0, recall: overlap / max(MapSet.size(expected), 1)}
  end

  defp exact_match?(_answer, []), do: false

  defp exact_match?(answer, expected) do
    normalized_answer = normalize_text(answer)
    Enum.any?(expected, &(normalize_text(&1) == normalized_answer))
  end

  defp contains_expected?(_answer, []), do: false

  defp contains_expected?(answer, expected) do
    normalized_answer = normalize_text(answer)

    Enum.any?(expected, fn expected ->
      normalized_expected = normalize_text(expected)
      normalized_expected != "" and String.contains?(normalized_answer, normalized_expected)
    end)
  end

  defp best_token_f1(_answer, []), do: 0.0

  defp best_token_f1(answer, expected) do
    answer_tokens = token_counts(answer)

    expected
    |> Enum.map(fn expected -> token_f1(answer_tokens, token_counts(expected)) end)
    |> Enum.max(fn -> 0.0 end)
  end

  defp token_f1(_answer_tokens, expected_tokens) when map_size(expected_tokens) == 0, do: 0.0
  defp token_f1(answer_tokens, _expected_tokens) when map_size(answer_tokens) == 0, do: 0.0

  defp token_f1(answer_tokens, expected_tokens) do
    overlap =
      expected_tokens
      |> Enum.reduce(0, fn {token, expected_count}, count ->
        count + min(expected_count, Map.get(answer_tokens, token, 0))
      end)

    if overlap == 0 do
      0.0
    else
      precision = overlap / Enum.sum(Map.values(answer_tokens))
      recall = overlap / Enum.sum(Map.values(expected_tokens))
      2 * precision * recall / (precision + recall)
    end
  end

  defp token_counts(value) do
    value
    |> normalize_text()
    |> String.split(" ", trim: true)
    |> Enum.frequencies()
  end

  defp normalize_text(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^[:alnum:]\s]+/u, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp not_known?(answer) do
    normalized = normalize_text(answer)
    Enum.any?(@not_known_markers, &String.contains?(normalized, normalize_text(&1)))
  end

  defp ratio(values, fun) do
    values
    |> Enum.count(fun)
    |> Kernel./(length(values))
  end

  defp mean(values, fun) do
    values
    |> Enum.map(fun)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> 0.0
      numbers -> Enum.sum(numbers) / length(numbers)
    end
  end

  defp optional_mean(values, key) do
    case Enum.filter(values, &is_number(Map.get(&1, key))) do
      [] -> nil
      scored -> mean(scored, &Map.get(&1, key))
    end
  end

  defp latency_summary([]), do: %{"mean" => 0.0, "p50" => 0, "p95" => 0, "max" => 0}

  defp latency_summary(latencies) do
    sorted = Enum.sort(latencies)

    %{
      "mean" => Enum.sum(sorted) / length(sorted),
      "p50" => percentile(sorted, 0.50),
      "p95" => percentile(sorted, 0.95),
      "max" => List.last(sorted)
    }
  end

  defp percentile(sorted, q) do
    index =
      sorted
      |> length()
      |> Kernel.*(q)
      |> Float.ceil()
      |> trunc()
      |> Kernel.-(1)
      |> max(0)

    Enum.at(sorted, index)
  end

  defp blank_to(nil, default), do: default
  defp blank_to("", default), do: default
  defp blank_to(value, _default), do: value
end
