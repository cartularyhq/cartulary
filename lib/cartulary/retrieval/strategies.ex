# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Retrieval.StrategySupport do
  @moduledoc false

  alias Cartulary.Retrieval.Candidate

  def candidates(rows, strategy, min_score \\ 0.0, source_filters \\ %{}) do
    rows
    |> Enum.filter(
      &(source_allowed?(&1, source_filters || %{}) and
          (&1["score"] || 0.0) >= min_score)
    )
    |> Enum.with_index(1)
    |> Enum.map(fn {row, rank} ->
      %Candidate{
        id: row["id"],
        score: (row["score"] || 0.0) * 1.0,
        rank: rank,
        strategy: strategy,
        record: Map.drop(row, ["score"]),
        evidence: %{"raw_score" => row["score"] || 0.0}
      }
    end)
  end

  defp source_allowed?(row, filters) do
    filters = Map.new(filters, fn {key, value} -> {to_string(key), value} end)

    matches?(row["extracting_provider"], filters["provider"]) and
      matches?(row["extracting_model"], filters["model"]) and
      matches?(row["pipeline_version"], filters["pipeline_version"]) and
      minimum?(row["corroboration_count"], filters["minimum_corroboration"]) and
      contains?(row["source_message_ids"], filters["source_message_id"]) and
      matches?(row["document_id"], filters["source_document_id"])
  end

  defp matches?(_actual, nil), do: true
  defp matches?(actual, expected), do: actual == expected
  defp minimum?(_actual, nil), do: true
  defp minimum?(actual, expected), do: (actual || 0) >= expected
  defp contains?(_actual, nil), do: true
  defp contains?(actual, expected), do: expected in (actual || [])
end

defmodule Cartulary.Retrieval.Strategies.Semantic do
  @moduledoc "Pinned-identity semantic retrieval over pgvector."
  @behaviour Cartulary.Retrieval.Strategy

  alias Cartulary.Model.{Config, Embedding}
  alias Cartulary.Retrieval.{Store, StrategySupport}

  @impl true
  def name, do: :semantic
  @impl true
  def cost_class, do: :moderate
  @impl true
  def stage, do: :seed
  @impl true
  def applicable?(query), do: is_binary(query.text) and String.trim(query.text) != ""

  @impl true
  def candidates(query, budget) do
    context = %{account_id: query.account_id, actor: query.actor}

    case Embedding.embed([query.text], context) do
      {:ok, %{vectors: [embedding]}} ->
        identity = :embedder |> Config.resolve(context) |> Config.embedding_identity()

        query
        |> Store.semantic(embedding, identity, budget.max_candidates)
        |> StrategySupport.candidates(
          name(),
          query.min_score || 0.0,
          query.source_filters
        )

      {:error, _error} ->
        []
    end
  end
end

defmodule Cartulary.Retrieval.Strategies.Lexical do
  @moduledoc "PostgreSQL full-text retrieval."
  @behaviour Cartulary.Retrieval.Strategy

  alias Cartulary.Retrieval.{Store, StrategySupport}

  @impl true
  def name, do: :lexical
  @impl true
  def cost_class, do: :cheap
  @impl true
  def stage, do: :seed
  @impl true
  def applicable?(query), do: is_binary(query.text) and String.trim(query.text) != ""

  @impl true
  def candidates(query, budget) do
    query
    |> Store.lexical(budget.max_candidates)
    |> StrategySupport.candidates(name(), query.min_score || 0.0, query.source_filters)
  end
end

defmodule Cartulary.Retrieval.Strategies.Temporal do
  @moduledoc "Belief/valid/relevant-time candidate generation."
  @behaviour Cartulary.Retrieval.Strategy

  alias Cartulary.Retrieval.{Store, StrategySupport}

  @impl true
  def name, do: :temporal
  @impl true
  def cost_class, do: :cheap
  @impl true
  def stage, do: :seed
  @impl true
  def applicable?(query), do: query.target in [:knowledge, :all]

  @impl true
  def candidates(query, budget) do
    query
    |> Store.temporal(budget.max_candidates)
    |> StrategySupport.candidates(name(), query.min_score || 0.0, query.source_filters)
  end
end

defmodule Cartulary.Retrieval.Strategies.SalienceRecency do
  @moduledoc "Embedding-free durability, salience, and decay ranking."
  @behaviour Cartulary.Retrieval.Strategy

  alias Cartulary.Retrieval.{Store, StrategySupport}

  @impl true
  def name, do: :salience_recency
  @impl true
  def cost_class, do: :cheap
  @impl true
  def stage, do: :seed
  @impl true
  def applicable?(query), do: query.target in [:knowledge, :all]

  @impl true
  def candidates(query, budget) do
    query
    |> Store.salience_recency(budget.max_candidates)
    |> StrategySupport.candidates(name(), query.min_score || 0.0, query.source_filters)
  end
end

defmodule Cartulary.Retrieval.Strategies.EntityMatch do
  @moduledoc "Alias-resolved statement retrieval without exposing entity data."
  @behaviour Cartulary.Retrieval.Strategy

  alias Cartulary.Retrieval.{Store, StrategySupport}

  @impl true
  def name, do: :entity_match
  @impl true
  def cost_class, do: :cheap
  @impl true
  def stage, do: :seed
  @impl true
  def applicable?(query), do: query.target in [:knowledge, :all] and query.text != ""

  @impl true
  def candidates(query, budget) do
    query
    |> Store.entity_match(budget.max_candidates)
    |> StrategySupport.candidates(name(), query.min_score || 0.0, query.source_filters)
  end
end

defmodule Cartulary.Retrieval.Strategies.RelationExpand do
  @moduledoc "Hop-one structural and shared-entity expansion."
  @behaviour Cartulary.Retrieval.Strategy

  alias Cartulary.Retrieval.{Store, StrategySupport}

  @impl true
  def name, do: :relation_expand
  @impl true
  def cost_class, do: :moderate
  @impl true
  def stage, do: :expand
  @impl true
  def applicable?(query), do: query.target in [:knowledge, :all] and query.seed_ids != []

  @impl true
  def candidates(query, budget) do
    query
    |> Store.relation_expand(budget.max_candidates)
    |> StrategySupport.candidates(name(), query.min_score || 0.0, query.source_filters)
  end
end
