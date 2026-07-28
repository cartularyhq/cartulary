# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Model.Gateway do
  @moduledoc """
  Provider-neutral gateway for every metered model capability.

  This is the only module that calls `Cartulary.Model.Provider` callbacks.
  """

  alias Cartulary.Model.Config
  alias Cartulary.Model.Provider.Result
  alias Cartulary.Model.Usage
  alias Cartulary.Observability

  def structured_once(role, messages, schema, context, opts \\ []) do
    config = Config.resolve(role, context)

    case invoke(:structured, config, context, opts, fn provider ->
           provider.structured(config, messages, schema, opts)
         end) do
      {:ok, %Result{value: value}} -> {:ok, value, config}
      {:error, error} -> {:error, error}
    end
  end

  def chat(role, messages, context, opts \\ []) do
    config = Config.resolve(role, context)

    case invoke(:chat, config, context, opts, fn provider ->
           provider.chat(config, messages, opts)
         end) do
      {:ok, %Result{value: value}} ->
        {:ok, value, Config.provenance(config)}

      {:error, error} ->
        {:error, error}
    end
  end

  def embed(texts, context, opts \\ []) when is_list(texts) do
    config = Config.resolve(:embedder, context)
    embed_with_config(config, texts, context, opts)
  end

  def embed_with_config(config, texts, context, opts) when is_list(texts) do
    case invoke(:embed, config, context, opts, fn provider ->
           provider.embed(config, texts, opts)
         end) do
      {:ok, %Result{value: value}} -> {:ok, value, config}
      {:error, error} -> {:error, error}
    end
  end

  def rerank(query, documents, context, opts \\ [])
      when is_binary(query) and is_list(documents) do
    config = Config.resolve(:dream_reasoner, context)

    case invoke(:rerank, config, context, opts, fn provider ->
           provider.rerank(config, query, documents, opts)
         end) do
      {:ok, %Result{value: value}} -> {:ok, value, Config.provenance(config)}
      {:error, error} -> {:error, error}
    end
  end

  def provider_module(config, context) do
    Map.get(context, :model_provider) ||
      Application.get_env(:cartulary, :model_provider) ||
      default_provider(config)
  end

  defp invoke(operation, config, context, opts, call) do
    Observability.with_span(:model, "cartulary.model.#{operation}", fn ->
      provider = provider_module(config, context)
      started_at = System.monotonic_time(:millisecond)

      Observability.set_attributes(:model, %{
        "cartulary.model.role" => Atom.to_string(config.role),
        "cartulary.model.provider" => config.provider,
        "cartulary.model.version" => config.model_version,
        "gen_ai.operation.name" => Atom.to_string(operation),
        "gen_ai.request.model" => config.model
      })

      result = safe_call(call, provider)
      duration_ms = System.monotonic_time(:millisecond) - started_at

      case result do
        {:ok, %Result{} = provider_result} ->
          Usage.emit(context, config, %{
            operation: operation,
            status: :ok,
            duration_ms: duration_ms,
            usage: provider_result.usage,
            metadata:
              provider_result.metadata
              |> Map.put(:repair_attempt, Keyword.get(opts, :repair_attempt, 0))
          })

          set_result_attributes(provider_result, duration_ms)
          {:ok, provider_result}

        {:error, error} ->
          Usage.emit(context, config, %{
            operation: operation,
            status: :error,
            duration_ms: duration_ms,
            usage: %{},
            metadata: %{
              error_class: error_class(error),
              repair_attempt: Keyword.get(opts, :repair_attempt, 0)
            }
          })

          Observability.set_attributes(:model, %{
            "cartulary.model.duration_ms" => duration_ms,
            "error.type" => error_class(error)
          })

          {:error, error}
      end
    end)
  end

  defp set_result_attributes(result, duration_ms) do
    usage = result.usage || %{}

    Observability.set_attributes(:model, %{
      "cartulary.model.duration_ms" => duration_ms,
      "gen_ai.usage.input_tokens" => Map.get(usage, :input_tokens, 0) || 0,
      "gen_ai.usage.output_tokens" => Map.get(usage, :output_tokens, 0) || 0,
      "cartulary.model.embedding_tokens" => Map.get(usage, :embedding_tokens, 0) || 0
    })
  end

  defp default_provider(%{provider: "deterministic"}),
    do: Cartulary.Model.Providers.Deterministic

  defp default_provider(%{provider: "ortex"}), do: Cartulary.Model.Providers.Ortex

  defp default_provider(_config), do: Cartulary.Model.Providers.ReqLLM

  defp safe_call(call, provider) do
    call.(provider)
  rescue
    error -> {:error, error}
  end

  defp error_class(%module{}), do: inspect(module)
  defp error_class(error) when is_atom(error), do: Atom.to_string(error)
  defp error_class(_error), do: "model_error"
end
