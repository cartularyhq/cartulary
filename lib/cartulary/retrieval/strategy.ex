# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Retrieval.Candidate do
  @moduledoc "A strategy-local ranked candidate before reciprocal-rank fusion."

  @enforce_keys [:id, :score, :rank, :strategy, :record]
  defstruct [:id, :score, :rank, :strategy, :record, evidence: %{}]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          score: float(),
          rank: pos_integer(),
          strategy: atom(),
          record: map(),
          evidence: map()
        }
end

defmodule Cartulary.Retrieval.Query do
  @moduledoc "Internal, already-authorized retrieval input."

  defstruct [
    :account_id,
    :actor,
    :text,
    :target,
    :as_of,
    :min_score,
    :source_filters,
    :query_embedding,
    scope_ids: [],
    seed_ids: [],
    max_candidates: 50
  ]

  @type t :: %__MODULE__{}
end

defmodule Cartulary.Retrieval.Budget do
  @moduledoc "Injected retrieval deadline and candidate cap."

  @enforce_keys [:started_at, :max_candidates]
  defstruct [:deadline_ms, :started_at, :max_candidates, deadline?: true]

  @type t :: %__MODULE__{}

  def remaining_ms(%__MODULE__{deadline?: false}), do: :infinity

  def remaining_ms(%__MODULE__{deadline_ms: deadline, started_at: started_at}) do
    max(deadline - (Cartulary.Clock.monotonic_ms() - started_at), 0)
  end
end

defmodule Cartulary.Retrieval.Strategy do
  @moduledoc """
  Candidate-generation contract from `AD-SEAM-3`.

  Strategies receive only an Account/scope-filtered internal query and return
  their own ranked score space. Scores are never compared across strategies.
  """

  alias Cartulary.Retrieval.{Budget, Candidate, Query}

  @callback name() :: atom()
  @callback cost_class() :: :cheap | :moderate | :expensive
  @callback stage() :: :seed | :expand
  @callback applicable?(Query.t()) :: boolean()
  @callback candidates(Query.t(), Budget.t()) :: [Candidate.t()]

  def validate!(module, candidates, max_candidates) do
    name = module.name()

    unless module.cost_class() in [:cheap, :moderate, :expensive],
      do: raise(ArgumentError, "#{inspect(module)} returned an invalid cost_class")

    unless module.stage() in [:seed, :expand],
      do: raise(ArgumentError, "#{inspect(module)} returned an invalid stage")

    candidates
    |> Enum.take(max_candidates)
    |> Enum.with_index(1)
    |> Enum.map(fn
      {%Candidate{id: id, score: score, record: record} = candidate, rank}
      when is_binary(id) and is_number(score) and is_map(record) ->
        %{candidate | rank: rank, strategy: name, score: score * 1.0}

      {invalid, _rank} ->
        raise ArgumentError,
              "#{inspect(module)} returned an invalid candidate: #{inspect(invalid)}"
    end)
  end
end
