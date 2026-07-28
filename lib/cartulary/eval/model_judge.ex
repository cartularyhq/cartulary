# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Eval.ModelJudge do
  @moduledoc """
  Optional independent-family release judge over the provider-neutral gateway.

  The dream-reasoner role judges answers produced by the dialectic role. A live
  run fails if those roles resolve to the same provider/model family.
  """

  alias Cartulary.Model.{Config, Gateway}

  @schema %{
    type: "object",
    properties: %{
      groundedness: %{type: "integer", minimum: 1, maximum: 5},
      context_relevance: %{type: "integer", minimum: 1, maximum: 5},
      answer_relevance: %{type: "integer", minimum: 1, maximum: 5}
    },
    required: [:groundedness, :context_relevance, :answer_relevance],
    additionalProperties: false
  }

  def identity do
    judge = Config.resolve(:dream_reasoner, %{})
    answer = Config.resolve(:dialectic_agent, %{})

    if family(judge) == family(answer) do
      raise ArgumentError,
            "eval judge must use a different provider/model family from dialectic answers"
    end

    judge
    |> Config.provenance()
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    |> Map.merge(%{"kind" => "model", "method" => "rag-triad-model-f11-1"})
  end

  def score(question, answer, candidates) do
    identity = identity()

    context =
      Enum.map_join(candidates, "\n", fn candidate ->
        Map.get(candidate, "statement") || Map.get(candidate, "content") || ""
      end)

    messages = [
      %{
        role: "system",
        content:
          "Score groundedness, context relevance, and answer relevance from 1 to 5. Return only schema-valid JSON."
      },
      %{
        role: "user",
        content: "Question:\n#{question}\n\nContext:\n#{context}\n\nAnswer:\n#{answer}"
      }
    ]

    case Gateway.structured_once(:dream_reasoner, messages, @schema, %{}, task: :eval_judge) do
      {:ok, value, _config} ->
        %{
          "model_groundedness" => normalized_score(value, :groundedness),
          "model_context_relevance" => normalized_score(value, :context_relevance),
          "model_answer_relevance" => normalized_score(value, :answer_relevance),
          "model_judge" => identity
        }

      {:error, error} ->
        raise ArgumentError, "model eval judge failed: #{inspect(error)}"
    end
  end

  defp normalized_score(value, key) do
    score = Map.get(value, key) || Map.get(value, Atom.to_string(key))

    if is_integer(score) and score in 1..5 do
      (score - 1) / 4
    else
      raise ArgumentError, "model eval judge returned invalid #{key}: #{inspect(score)}"
    end
  end

  defp family(config), do: {config.provider, config.model}
end
