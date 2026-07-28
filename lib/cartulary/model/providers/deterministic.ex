# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Model.Providers.Deterministic do
  @moduledoc """
  Explicit test/local fallback provider.

  This adapter is never selected as a production fallback after another
  provider fails. Operators must opt into it by role configuration.
  """

  @behaviour Cartulary.Model.Provider

  alias Cartulary.Model.Provider.Result

  @impl true
  def structured(_config, messages, _schema, opts) do
    value =
      case Keyword.get(opts, :task) do
        :extraction -> %{"items" => extraction_items(messages, opts)}
        :reasoning -> %{"items" => [], "relations" => []}
        :dialectic -> %{"answer" => "not known", "citations" => [], "abstained" => true}
        _other -> %{}
      end

    {:ok, %Result{value: value, metadata: %{fallback: true}}}
  end

  @impl true
  def chat(_config, _messages, _opts),
    do: {:ok, %Result{value: "not known", metadata: %{fallback: true}}}

  @impl true
  def embed(_config, _texts, _opts),
    do: {:error, :deterministic_embeddings_are_not_an_architectural_embedder}

  @impl true
  def rerank(_config, _query, documents, _opts) do
    ranked =
      documents
      |> Enum.with_index()
      |> Enum.map(fn {document, index} ->
        %{index: index, relevance_score: 1.0 / (index + 1), document: document}
      end)

    {:ok, %Result{value: ranked, metadata: %{fallback: true}}}
  end

  defp extraction_items(messages, opts) do
    content = Keyword.get(opts, :observation) || last_user_content(messages)
    source_peer_key = Keyword.get(opts, :source_peer_key)

    content
    |> String.split(~r/(?<=[.!?])\s+|\n+/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(String.length(&1) < 12))
    |> Enum.take(6)
    |> Enum.map(fn statement ->
      %{
        "statement" => statement,
        "kind" => infer_kind(statement),
        "subject_type" => "peer",
        "subject_ref" => source_peer_key,
        "confidence" => 0.55,
        "sensitivity" => infer_sensitivity(statement),
        "target_level" => "peer",
        "update_operation" => "add",
        "hearsay" => false,
        "expires_at" => nil,
        "revalidate_after" => nil,
        "relevant_from" => nil,
        "relevant_until" => nil
      }
    end)
  end

  defp last_user_content(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value("", fn message ->
      role = Map.get(message, :role) || Map.get(message, "role")
      content = Map.get(message, :content) || Map.get(message, "content")
      if role in [:user, "user"] and is_binary(content), do: content
    end)
  end

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
