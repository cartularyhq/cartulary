# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Model.Providers.ReqLLM do
  @moduledoc "ReqLLM-backed provider for structured, chat, embedding, and rerank calls."

  @behaviour Cartulary.Model.Provider

  alias Cartulary.Model.Config.Role
  alias Cartulary.Model.Provider.Result

  @request_option_keys ~w(base_url max_tokens max_retries receive_timeout temperature top_p)a

  @impl true
  def structured(%Role{} = config, messages, schema, opts) do
    with {:ok, response} <-
           ReqLLM.generate_object(
             model_spec(config),
             messages,
             schema,
             request_opts(config, opts)
           ),
         value when is_map(value) <- ReqLLM.Response.object(response) do
      {:ok,
       %Result{
         value: value,
         usage: usage(response.usage),
         metadata: %{response_model: response.model}
       }}
    else
      nil -> {:error, :missing_structured_object}
      {:error, error} -> {:error, error}
    end
  end

  @impl true
  def chat(%Role{} = config, messages, opts) do
    with {:ok, response} <-
           ReqLLM.generate_text(model_spec(config), messages, request_opts(config, opts)),
         value when is_binary(value) <- ReqLLM.Response.text(response) do
      {:ok,
       %Result{
         value: value,
         usage: usage(response.usage),
         metadata: %{response_model: response.model}
       }}
    else
      nil -> {:error, :missing_text_response}
      {:error, error} -> {:error, error}
    end
  end

  @impl true
  def embed(%Role{} = config, texts, opts) do
    req_opts = Keyword.put(request_opts(config, opts), :return_usage, true)

    case ReqLLM.embed(model_spec(config), texts, req_opts) do
      {:ok, %{embedding: vectors, usage: provider_usage}} ->
        {:ok,
         %Result{
           value: vectors,
           usage: embedding_usage(provider_usage),
           metadata: %{vector_count: length(vectors)}
         }}

      {:ok, vectors} when is_list(vectors) ->
        {:ok, %Result{value: vectors, metadata: %{vector_count: length(vectors)}}}

      {:error, error} ->
        {:error, error}
    end
  end

  @impl true
  def rerank(%Role{} = config, query, documents, opts) do
    req_opts =
      config
      |> request_opts(opts)
      |> Keyword.merge(query: query, documents: documents)

    case ReqLLM.Rerank.rerank(model_spec(config), req_opts) do
      {:ok, response} ->
        {:ok,
         %Result{
           value: response.results,
           usage: response.meta |> Map.get(:usage, %{}) |> usage(),
           metadata: %{result_count: length(response.results)}
         }}

      {:error, error} ->
        {:error, error}
    end
  end

  defp model_spec(%Role{provider: provider, model: model, options: options})
       when provider in ["openai", "openai-compatible"] do
    %{
      provider: :openai,
      id: model,
      base_url: Map.get(options, "base_url")
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> ReqLLM.model!()
  end

  defp model_spec(%Role{provider: provider, model: model}) do
    "#{provider}:#{model}"
  end

  defp request_opts(%Role{options: options}, overrides) do
    configured =
      @request_option_keys
      |> Enum.reduce([], fn key, acc ->
        case Map.get(options, Atom.to_string(key)) do
          nil -> acc
          value -> [{key, value} | acc]
        end
      end)

    configured
    |> maybe_put(:api_key, resolve_api_key(options))
    |> Keyword.merge(Keyword.take(overrides, @request_option_keys))
  end

  defp resolve_api_key(options) do
    legacy = Application.get_env(:cartulary, :models, [])

    Keyword.get(legacy, :api_key) ||
      case Map.get(options, "api_key_ref") || Keyword.get(legacy, :api_key_ref) do
        "env:" <> variable -> System.get_env(variable)
        _other -> nil
      end
  end

  defp maybe_put(keyword, _key, nil), do: keyword
  defp maybe_put(keyword, _key, ""), do: keyword
  defp maybe_put(keyword, key, value), do: Keyword.put(keyword, key, value)

  defp usage(value), do: ReqLLM.Usage.normalize(value || %{})

  defp embedding_usage(value) do
    normalized = usage(value)

    normalized
    |> Map.put(:embedding_tokens, Map.get(normalized, :input_tokens, 0) || 0)
    |> Map.put(:output_tokens, 0)
  end
end
