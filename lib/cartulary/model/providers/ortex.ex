# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Model.Providers.Ortex do
  @moduledoc "Provider capability wrapper around the local Ortex embedding model."

  @behaviour Cartulary.Model.Provider

  alias Cartulary.Model.Config.Role
  alias Cartulary.Model.Embedding.Ortex
  alias Cartulary.Model.Provider.Result

  @impl true
  def structured(_config, _messages, _schema, _opts),
    do: {:error, :ortex_is_embedding_only}

  @impl true
  def chat(_config, _messages, _opts), do: {:error, :ortex_is_embedding_only}

  @impl true
  def embed(%Role{} = config, texts, _opts) do
    opts = embedding_opts(config)

    with {:ok, vectors} <- Ortex.generate(texts, opts),
         {:ok, tokens} <- Ortex.token_count(texts, opts) do
      {:ok,
       %Result{
         value: vectors,
         usage: %{embedding_tokens: tokens},
         metadata: %{vector_count: length(vectors)}
       }}
    end
  end

  @impl true
  def rerank(_config, _query, _documents, _opts),
    do: {:error, :ortex_embedding_model_cannot_rerank}

  defp embedding_opts(config) do
    options = config.options

    [
      dimensions: config.embedding_dimensions,
      cache_key: {config.provider, config.model, config.model_version},
      model_path: Map.get(options, "model_path"),
      tokenizer_path: Map.get(options, "tokenizer_path"),
      max_length: Map.get(options, "max_length", 256),
      output_index: Map.get(options, "output_index", 0),
      input_order: Map.get(options, "input_order", ~w(input_ids attention_mask token_type_ids)),
      pooling: pooling(Map.get(options, "pooling", "cls")),
      execution_providers:
        options
        |> Map.get("execution_providers", ["cpu"])
        |> Enum.map(&execution_provider/1)
    ]
  end

  defp execution_provider("cpu"), do: :cpu
  defp execution_provider("coreml"), do: :coreml
  defp execution_provider("cuda"), do: :cuda
  defp execution_provider("tensorrt"), do: :tensorrt
  defp execution_provider(provider) when is_atom(provider), do: provider
  defp execution_provider(_provider), do: :cpu

  defp pooling("mean"), do: :mean
  defp pooling(:mean), do: :mean
  defp pooling(_pooling), do: :cls
end
