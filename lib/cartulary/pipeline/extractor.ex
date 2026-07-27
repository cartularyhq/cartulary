# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Pipeline.Extractor do
  @moduledoc """
  Converts raw observations into proposed natural-language knowledge.

  The fallback extractor is intentionally simple and deterministic so tests and
  local smoke runs can proceed without spending model tokens.
  """

  alias Cartulary.Model.OpenRouter

  require Logger

  @pipeline_version "poc-0"

  def pipeline_version, do: @pipeline_version

  def extract(message) do
    if model_configured?() do
      model_extract(message)
    else
      fallback_extract(message)
    end
  rescue
    error ->
      Logger.warning(
        "Cartulary extraction fell back to deterministic POC extractor: #{Exception.message(error)}"
      )

      fallback_extract(message)
  end

  defp model_configured? do
    key =
      Keyword.get(Application.fetch_env!(:cartulary, :models), :api_key) ||
        System.get_env("OPENROUTER_API_KEY")

    is_binary(key) and key != ""
  end

  defp model_extract(message) do
    content = Map.fetch!(message, "content")

    decoded =
      OpenRouter.chat_json!(:ingest, [
        %{
          role: "system",
          content: """
          Extract durable agent-memory knowledge from one raw observation.
          Return strict JSON: {"items":[{"statement": "...", "kind": "fact|preference|event|relation|skill", "confidence": 0.0-1.0, "sensitivity": "public|internal|personal|restricted"}]}.
          Store natural-language statements only. Do not invent facts.
          If there is no durable knowledge, return {"items":[]}.
          """
        },
        %{role: "user", content: content}
      ])

    decoded
    |> Map.get("items", [])
    |> Enum.filter(&is_map/1)
    |> Enum.map(&normalize_item(&1, OpenRouter.role_model(:ingest)))
  end

  defp fallback_extract(%{"content" => content}) do
    content
    |> String.split(~r/(?<=[.!?])\s+|\n+/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(String.length(&1) < 12))
    |> Enum.take(6)
    |> Enum.map(fn statement ->
      normalize_item(
        %{
          "statement" => statement,
          "kind" => infer_kind(statement),
          "confidence" => 0.55,
          "sensitivity" => infer_sensitivity(statement)
        },
        "fallback:poc-0"
      )
    end)
  end

  defp normalize_item(item, model) do
    %{
      statement: item |> Map.get("statement", "") |> String.trim(),
      kind:
        item
        |> Map.get("kind", "fact")
        |> normalize_enum(~w(fact preference event relation skill), "fact"),
      confidence: item |> Map.get("confidence", 0.5) |> normalize_confidence(),
      sensitivity:
        item
        |> Map.get("sensitivity", "internal")
        |> normalize_enum(~w(public internal personal restricted), "internal"),
      extracting_model: model,
      pipeline_version: @pipeline_version
    }
  end

  defp normalize_enum(value, allowed, default) when is_binary(value) do
    value = String.downcase(value)
    if value in allowed, do: value, else: default
  end

  defp normalize_enum(_value, _allowed, default), do: default

  defp normalize_confidence(value) when is_number(value), do: value |> max(0.0) |> min(1.0)
  defp normalize_confidence(_value), do: 0.5

  defp infer_kind(statement) do
    cond do
      String.match?(statement, ~r/\b(prefers|likes|wants|needs|favorite)\b/i) ->
        "preference"

      String.match?(statement, ~r/\b(on|at|by|before|after|yesterday|today|tomorrow)\b/i) ->
        "event"

      true ->
        "fact"
    end
  end

  defp infer_sensitivity(statement) do
    if String.match?(statement, ~r/\b(email|phone|address|health|medical|salary|ssn)\b/i) do
      "personal"
    else
      "internal"
    end
  end
end
