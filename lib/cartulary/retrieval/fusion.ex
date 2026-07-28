# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Retrieval.Fusion do
  @moduledoc """
  Merges the per-strategy candidate lists into one ranked list, and summarises
  how much the strategies disagreed before they were merged.

  ## Why rank, not score

  Each strategy scores on its own scale: pgvector cosine similarity, full-text
  rank, a time-relevance step function, a salience-times-decay product, and
  mention confidence. Those numbers have no common meaning, so adding,
  averaging, or thresholding them across strategies is arithmetic on unlike
  units and produces confidently wrong orderings. Fusion therefore throws the
  values away and uses only each candidate's position inside its own list.

  A candidate found by several strategies accumulates one contribution per
  strategy, which is the whole point: agreement between independent retrieval
  methods is the strongest signal available here, and it emerges from the sum
  rather than from any tuned rule.

  Per-strategy weights scale a strategy's vote in the merge. They are not score
  multipliers and never touch a candidate's own score.

  ## Disagreement is measured before merging

  Once the lists are merged, the fact that two strategies returned entirely
  different records is unrecoverable. `disagreement/1` is therefore computed on
  the pre-fusion lists and reported alongside the answer so a caller can tell
  "several methods agreed on this" from "nothing really matched, here are the
  least-bad rows".
  """

  alias Cartulary.Retrieval.Candidate

  @doc """
  Fuses per-strategy candidate lists into one ranked list of at most `limit`
  candidates.

  `lists` is a list of `{strategy_name, candidates}` pairs; `weights` maps a
  strategy name to its multiplier, defaulting to 1.0 for anything unlisted.

  A candidate's fused score is the sum over the strategies that proposed it of
  `weight / (k + rank)`, where `rank` is its 1-based position in that
  strategy's own list and `k` is the fusion constant from application
  configuration. A large `k` flattens the curve, so one strategy's single top
  hit cannot dominate a candidate that several strategies ranked moderately.

  Returns `Candidate` structs marked `strategy: :fusion`, with `score` holding
  the fused total, `rank` renumbered from 1, and `evidence` listing the
  contributing strategies. The record kept for a duplicated candidate is the
  copy whose strategy-local score was highest — an arbitrary but deterministic
  choice, since all copies describe the same underlying row.

  Raises `KeyError` if the fusion constant is missing from configuration.
  """
  def reciprocal_rank(lists, weights, limit) do
    k = retrieval_config(:rrf_k)

    lists
    |> Enum.flat_map(fn {_strategy, candidates} -> candidates end)
    |> Enum.group_by(& &1.id)
    |> Enum.map(fn {_id, candidates} ->
      # One term per strategy that proposed this candidate. Only `rank` is
      # read; `candidate.score` is deliberately not part of the sum.
      score =
        Enum.reduce(candidates, 0.0, fn candidate, total ->
          weight = Map.get(weights, candidate.strategy, 1.0)
          total + weight / (k + candidate.rank)
        end)

      strategies = candidates |> Enum.map(& &1.strategy) |> Enum.uniq()

      # Copies of the same row differ only in strategy metadata, so picking by
      # strategy-local score is just a stable way to choose one of them.
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

  @doc """
  Summarises how much the strategies disagreed, from their pre-fusion lists.

  Must be called with the lists as the strategies produced them; calling it on
  a fused list is meaningless, because fusion has already collapsed the
  per-strategy views into one.

  Returns a map with:

  * `"strategy_count"` — how many strategies returned anything at all.
  * `"disjoint"` — true when at least one strategy produced results and no two
    strategies share a single candidate. Independent methods agreeing on
    nothing usually means the query matched nothing well.
  * `"low_score"` — true when every strategy's best strategy-local score is
    under 0.2. This compares each strategy against a fixed floor rather than
    against another strategy, which is why using raw scores is legitimate here;
    it is a weak "nothing looked good" hint, not a relevance measure.

  With no non-empty lists, `"disjoint"` is false and `"low_score"` is true,
  because a vacuous `Enum.all?/2` holds.
  """
  def disagreement(lists) do
    non_empty =
      for {strategy, candidates} <- lists, candidates != [] do
        {strategy, MapSet.new(candidates, & &1.id), Enum.max_by(candidates, & &1.score).score}
      end

    # `left < right` compares the strategy name atoms purely to visit each
    # unordered pair once, avoiding self-comparisons and mirrored duplicates.
    overlaps =
      for {left, left_ids, _} <- non_empty,
          {right, right_ids, _} <- non_empty,
          left < right do
        MapSet.intersection(left_ids, right_ids) |> MapSet.size()
      end

    %{
      "strategy_count" => length(non_empty),
      "disjoint" => non_empty != [] and Enum.all?(overlaps, &(&1 == 0)),
      # 0.2 is a fixed floor applied to each strategy's own best score, on
      # whatever scale that strategy uses. It is a hint, never a filter:
      # nothing is dropped because of it.
      "low_score" => Enum.all?(non_empty, fn {_strategy, _ids, score} -> score < 0.2 end)
    }
  end

  # Fusion tuning lives beside the profile definitions because changing it
  # changes ranking for every profile at once.
  defp retrieval_config(key) do
    :cartulary
    |> Application.fetch_env!(:retrieval_profiles)
    |> Keyword.fetch!(key)
  end
end
