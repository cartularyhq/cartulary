# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Model.Embedding.Ortex do
  @moduledoc """
  Local/offline `AshAi.EmbeddingModel` backed by Ortex and ONNX Runtime.

  Model and tokenizer artifacts are explicit local paths. Cartulary never
  downloads or silently swaps an embedding model at runtime.
  """

  use AshAi.EmbeddingModel

  alias Tokenizers.Encoding
  alias Tokenizers.Tokenizer

  @default_max_length 256
  @default_input_order ~w(input_ids attention_mask token_type_ids)

  @impl true
  def dimensions(opts), do: Keyword.fetch!(opts, :dimensions)

  @impl true
  def generate(texts, opts) when is_list(texts) do
    with {:ok, model_path} <- artifact(opts, :model_path),
         {:ok, tokenizer_path} <- artifact(opts, :tokenizer_path),
         cache_key = Keyword.get(opts, :cache_key),
         {:ok, tokenizer} <- cached_tokenizer(tokenizer_path, cache_key),
         {:ok, model} <-
           cached_model(
             model_path,
             Keyword.get(opts, :execution_providers, [:cpu]),
             cache_key
           ),
         {:ok, encoded} <- encode(tokenizer, texts, opts) do
      run(model, encoded, opts)
    end
  rescue
    error -> {:error, {:ortex_inference_failed, error.__struct__}}
  end

  def token_count(texts, opts) do
    with {:ok, tokenizer_path} <- artifact(opts, :tokenizer_path),
         {:ok, tokenizer} <- cached_tokenizer(tokenizer_path, Keyword.get(opts, :cache_key)),
         {:ok, encoded} <- encode(tokenizer, texts, opts) do
      {:ok, encoded.attention_mask |> List.flatten() |> Enum.sum()}
    end
  end

  defp artifact(opts, key) do
    case Keyword.get(opts, key) do
      path when is_binary(path) and path != "" ->
        if File.regular?(path), do: {:ok, path}, else: {:error, {:model_artifact_missing, key}}

      _other ->
        {:error, {:model_artifact_missing, key}}
    end
  end

  defp cached_tokenizer(path, model_key) do
    cache({__MODULE__, :tokenizer, model_key, path}, fn -> Tokenizer.from_file(path) end)
  end

  defp cached_model(path, execution_providers, model_key) do
    cache({__MODULE__, :model, model_key, path, execution_providers}, fn ->
      {:ok, Ortex.load(path, execution_providers)}
    end)
  end

  defp cache(key, loader) do
    case :persistent_term.get(key, :missing) do
      :missing ->
        with {:ok, value} <- loader.() do
          :persistent_term.put(key, value)
          {:ok, value}
        end

      value ->
        {:ok, value}
    end
  end

  defp encode(tokenizer, texts, opts) do
    max_length = Keyword.get(opts, :max_length, @default_max_length)

    with {:ok, encodings} <- Tokenizer.encode_batch(tokenizer, Enum.map(texts, &(&1 || ""))) do
      target_length =
        encodings
        |> Enum.map(&min(Encoding.get_length(&1), max_length))
        |> Enum.max(fn -> 1 end)

      encodings =
        Enum.map(encodings, fn encoding ->
          encoding
          |> Encoding.truncate(target_length)
          |> Encoding.pad(target_length)
        end)

      {:ok,
       %{
         input_ids: Enum.map(encodings, &Encoding.get_ids/1),
         attention_mask: Enum.map(encodings, &Encoding.get_attention_mask/1),
         token_type_ids: Enum.map(encodings, &Encoding.get_type_ids/1)
       }}
    end
  end

  defp run(model, encoded, opts) do
    inputs =
      opts
      |> Keyword.get(:input_order, @default_input_order)
      |> Enum.map(fn name ->
        encoded
        |> Map.fetch!(normalize_input_name(name))
        |> Nx.tensor(type: :s64)
      end)
      |> List.to_tuple()

    output =
      model
      |> Ortex.run(inputs)
      |> Tuple.to_list()
      |> Enum.at(Keyword.get(opts, :output_index, 0))
      |> Nx.backend_transfer()

    vectors =
      case Nx.shape(output) do
        {_batch, _dimensions} ->
          Nx.to_list(output)

        {_batch, _sequence, _dimensions} ->
          pool(Nx.to_list(output), encoded.attention_mask, Keyword.get(opts, :pooling, :cls))

        shape ->
          raise ArgumentError, "unsupported embedding output rank #{tuple_size(shape)}"
      end

    {:ok, Enum.map(vectors, &normalize/1)}
  end

  defp mean_pool(hidden_batches, masks) do
    Enum.zip_with(hidden_batches, masks, fn hidden, mask ->
      dimensions = hidden |> List.first([]) |> length()

      {sum, count} =
        Enum.zip(hidden, mask)
        |> Enum.reduce({List.duplicate(0.0, dimensions), 0}, fn
          {token, 1}, {sum, count} ->
            {Enum.zip_with(sum, token, &(&1 + &2)), count + 1}

          {_token, _masked}, acc ->
            acc
        end)

      divisor = max(count, 1)
      Enum.map(sum, &(&1 / divisor))
    end)
  end

  defp pool(hidden_batches, _masks, :cls), do: Enum.map(hidden_batches, &List.first/1)
  defp pool(hidden_batches, masks, :mean), do: mean_pool(hidden_batches, masks)

  defp normalize(vector) do
    magnitude = vector |> Enum.reduce(0.0, &(&2 + &1 * &1)) |> :math.sqrt()
    if magnitude == 0.0, do: vector, else: Enum.map(vector, &(&1 / magnitude))
  end

  defp normalize_input_name(name) when is_atom(name), do: name
  defp normalize_input_name("input_ids"), do: :input_ids
  defp normalize_input_name("attention_mask"), do: :attention_mask
  defp normalize_input_name("token_type_ids"), do: :token_type_ids

  defp normalize_input_name(name),
    do: raise(ArgumentError, "unsupported ONNX embedding input #{inspect(name)}")
end

defmodule Cartulary.Model.Embedding.ReqLLM do
  @moduledoc "API/self-hosted OpenAI-compatible `AshAi.EmbeddingModel` adapter."

  use AshAi.EmbeddingModel

  @impl true
  defdelegate dimensions(opts), to: AshAi.EmbeddingModels.ReqLLM

  @impl true
  defdelegate generate(texts, opts), to: AshAi.EmbeddingModels.ReqLLM
end
