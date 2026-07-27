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

  def score_question(question, result, cited_refs) do
    expected = Map.get(question, :expected, [])
    answer = result |> Map.get("answer", "") |> to_string()
    abstention_expected? = Map.get(question, :abstention_expected, false)
    abstained? = Map.get(result, "abstained", false) == true or not_known?(answer)
    token_f1 = best_token_f1(answer, expected)
    contains_expected? = contains_expected?(answer, expected)
    exact_match? = exact_match?(answer, expected)
    evidence_refs = Map.get(question, :evidence_refs, [])
    citation = citation_score(evidence_refs, cited_refs)

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
      "latency_ms" => results |> Enum.map(&Map.get(&1, "latency_ms", 0)) |> latency_summary()
    }
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
