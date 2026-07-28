# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Retrieval.Fusion do
  @moduledoc "Weighted reciprocal-rank fusion and pre-fusion disagreement."

  alias Cartulary.Retrieval.Candidate

  def reciprocal_rank(lists, weights, limit) do
    k = retrieval_config(:rrf_k)

    lists
    |> Enum.flat_map(fn {_strategy, candidates} -> candidates end)
    |> Enum.group_by(& &1.id)
    |> Enum.map(fn {_id, candidates} ->
      score =
        Enum.reduce(candidates, 0.0, fn candidate, total ->
          weight = Map.get(weights, candidate.strategy, 1.0)
          total + weight / (k + candidate.rank)
        end)

      strategies = candidates |> Enum.map(& &1.strategy) |> Enum.uniq()
      %Candidate{} = representative = Enum.max_by(candidates, & &1.score)

      %Candidate{
        representative
        | score: score,
          rank: 0,
          strategy: :fusion,
          evidence: %{"strategies" => strategies}
      }
    end)
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(limit)
    |> Enum.with_index(1)
    |> Enum.map(fn {candidate, rank} -> %{candidate | rank: rank} end)
  end

  def disagreement(lists) do
    non_empty =
      for {strategy, candidates} <- lists, candidates != [] do
        {strategy, MapSet.new(candidates, & &1.id), Enum.max_by(candidates, & &1.score).score}
      end

    overlaps =
      for {left, left_ids, _} <- non_empty,
          {right, right_ids, _} <- non_empty,
          left < right do
        MapSet.intersection(left_ids, right_ids) |> MapSet.size()
      end

    %{
      "strategy_count" => length(non_empty),
      "disjoint" => non_empty != [] and Enum.all?(overlaps, &(&1 == 0)),
      "low_score" => Enum.all?(non_empty, fn {_strategy, _ids, score} -> score < 0.2 end)
    }
  end

  defp retrieval_config(key) do
    :cartulary
    |> Application.fetch_env!(:retrieval_profiles)
    |> Keyword.fetch!(key)
  end
end
