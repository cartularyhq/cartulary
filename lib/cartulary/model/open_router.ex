# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Model.OpenRouter do
  @moduledoc """
  OpenAI-compatible model client used for the local POC.
  """

  @headers [
    {"content-type", "application/json"},
    {"x-openrouter-title", "Cartulary Local POC"}
  ]

  def role_model(role) when role in [:ingest, :dream, :ask] do
    models = Application.fetch_env!(:cartulary, :models)
    Keyword.fetch!(models, role)
  end

  def chat_json!(role, messages, opts \\ []) do
    content = chat!(role, messages, Keyword.put(opts, :json, true))

    case Jason.decode(content) do
      {:ok, decoded} ->
        decoded

      {:error, error} ->
        raise ArgumentError, "model returned invalid JSON: #{Exception.message(error)}"
    end
  end

  def chat!(role, messages, opts \\ []) do
    models = Application.fetch_env!(:cartulary, :models)

    api_key =
      Keyword.get(models, :api_key) || System.get_env(Keyword.fetch!(models, :api_key_env))

    if is_nil(api_key) or api_key == "" do
      raise ArgumentError, "OPENROUTER_API_KEY is not configured"
    end

    body = %{
      model: Keyword.fetch!(models, role),
      messages: messages,
      temperature: Keyword.get(opts, :temperature, 0.1)
    }

    body =
      if Keyword.get(opts, :json, false) do
        Map.put(body, :response_format, %{type: "json_object"})
      else
        body
      end

    url = String.trim_trailing(Keyword.fetch!(models, :base_url), "/") <> "/chat/completions"

    case Req.post(url, auth: {:bearer, api_key}, headers: @headers, json: body) do
      {:ok, %{status: status, body: response}} when status in 200..299 ->
        response
        |> get_in(["choices", Access.at(0), "message", "content"])
        |> case do
          content when is_binary(content) -> content
          _ -> raise ArgumentError, "model response did not include message content"
        end

      {:ok, %{status: status, body: body}} ->
        raise ArgumentError, "model request failed with status #{status}: #{inspect(body)}"

      {:error, reason} ->
        raise ArgumentError, "model request failed: #{inspect(reason)}"
    end
  end
end
