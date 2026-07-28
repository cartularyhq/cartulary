# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Model.Providers.Ortex do
  @moduledoc """
  Provider adapter for the local ONNX embedding runtime.

  This is the default embedder, and the reason a fresh install can embed with no
  API key, no network access, and no per-token cost. It serves the embedding
  capability only; the three generation capabilities return an error rather than
  a degraded answer, so a role misconfigured to point generation at the local
  embedder fails loudly instead of quietly producing nothing useful.

  Its job is translation: turn a resolved role's options into the argument list
  the runtime wants, and turn the runtime's output into a provider result with
  real token counts. Every knob — artifact paths, sequence length, pooling,
  execution providers — comes from role options. Sequence length, pooling, and
  the artifacts themselves change the coordinates a text maps to, so changing
  one obliges a bump of the role's `model_version`; the options are not
  themselves part of the recorded embedding identity.
  """

  @behaviour Cartulary.Model.Provider

  alias Cartulary.Model.Config.Role
  alias Cartulary.Model.Embedding.Ortex
  alias Cartulary.Model.Provider.Result

  @doc """
  Not supported: this is an embedding runtime and cannot generate objects.
  """
  @impl true
  def structured(_config, _messages, _schema, _opts),
    do: {:error, :ortex_is_embedding_only}

  @doc """
  Not supported: this is an embedding runtime and cannot generate text.
  """
  @impl true
  def chat(_config, _messages, _opts), do: {:error, :ortex_is_embedding_only}

  @doc """
  Embeds texts locally and reports the tokens the tokenizer actually produced.

  Token counts come from a second pass over the same encoding rather than an
  estimate, so the usage ledger records local embedding spend as precisely as it
  records a hosted call — worth having even though local tokens cost nothing,
  because capacity planning depends on it.
  """
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

  @doc """
  Not supported: an embedding model has no cross-encoder to rerank with.
  """
  @impl true
  def rerank(_config, _query, _documents, _opts),
    do: {:error, :ortex_embedding_model_cannot_rerank}

  # Translates role options into runtime arguments.
  #
  # The cache key is provider, model, and model version together, which is what
  # makes a version bump load fresh artifacts instead of serving the previously
  # cached session. Since the model version is required to change whenever the
  # artifact, tokenizer, or pooling changes, this cannot serve stale weights for
  # a changed embedding identity.
  #
  # Defaults below are chosen for the shipped sentence-embedding model:
  defp embedding_opts(config) do
    options = config.options

    [
      dimensions: config.embedding_dimensions,
      cache_key: {config.provider, config.model, config.model_version},
      model_path: Map.get(options, "model_path"),
      tokenizer_path: Map.get(options, "tokenizer_path"),
      # Tokens per text. Longer inputs are truncated; 256 covers a typical
      # statement or chunk while bounding inference cost, which grows with
      # sequence length.
      max_length: Map.get(options, "max_length", 256),
      # Which ONNX output tensor holds the hidden states. 0 is first, correct
      # for the usual single-output encoder export.
      output_index: Map.get(options, "output_index", 0),
      # Input tensor order must match the exported graph's signature exactly;
      # this is the standard encoder triple.
      input_order: Map.get(options, "input_order", ~w(input_ids attention_mask token_type_ids)),
      # How token vectors collapse into one sentence vector. Must match how the
      # model was trained; changing it changes the coordinates, so it obliges a
      # `model_version` bump and a re-embed.
      pooling: pooling(Map.get(options, "pooling", "cls")),
      execution_providers:
        options
        |> Map.get("execution_providers", ["cpu"])
        |> Enum.map(&execution_provider/1)
    ]
  end

  # Hardware backends. CPU is the default because it is the only one available
  # everywhere; an unrecognized string degrades to CPU rather than failing,
  # since the wrong accelerator name should slow a deployment down, not stop it
  # embedding. An atom is passed through untranslated for a backend the runtime
  # knows but this list does not.
  defp execution_provider("cpu"), do: :cpu
  defp execution_provider("coreml"), do: :coreml
  defp execution_provider("cuda"), do: :cuda
  defp execution_provider("tensorrt"), do: :tensorrt
  defp execution_provider(provider) when is_atom(provider), do: provider
  defp execution_provider(_provider), do: :cpu

  # Anything not explicitly "mean" is treated as CLS pooling, matching the
  # default above. A typo therefore produces the documented default rather than
  # a crash mid-embedding.
  defp pooling("mean"), do: :mean
  defp pooling(:mean), do: :mean
  defp pooling(_pooling), do: :cls
end
