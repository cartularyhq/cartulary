# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Model.Providers.ReqLLM do
  @moduledoc """
  The HTTP model adapter: one module serving every hosted, self-hosted, and
  OpenAI-compatible endpoint.

  There is deliberately no per-vendor module. Anything reachable over HTTP —
  a hosted aggregator, a vendor API, a locally run OpenAI-compatible server — is
  configured by naming a provider and a model on the role, optionally with a
  base URL. That is what keeps the deployment free of vendor lock-in without a
  matrix of adapters to maintain.

  ## Credentials

  A role's options carry a *reference* to a credential, spelled `"env:NAME"`,
  and this module resolves it from the environment at call time. The credential
  itself is never stored in role configuration, never written to a usage record,
  and never placed in a span. The one place a raw key could still be configured
  is the legacy `config :cartulary, :models, api_key:` entry, which ships as
  `nil` and is read ahead of the reference when set.

  ## Request options

  Only a fixed set of request knobs is honoured: base URL, max tokens, max
  retries, receive timeout, temperature, and top-p. Per-call options override
  configured ones. The allowlist is deliberate — arbitrary keys from stored
  configuration must not be able to reshape an outbound request.

  ## Failure behaviour

  Errors are returned rather than raised, and a response that is missing the
  object or text it should contain is an error too, not an empty success. The
  gateway meters the failure and the caller's job retries; nothing here
  substitutes fabricated output for a failed call.
  """

  @behaviour Cartulary.Model.Provider

  alias Cartulary.Model.Config.Role
  alias Cartulary.Model.Provider.Result

  # The only role options that may become outbound request options. Anything
  # else in the options map is configuration for this adapter, not for the
  # request, and must not be forwarded. `reasoning_effort` bounds how much a
  # reasoning model spends on internal reasoning tokens before it ever emits
  # output — capping `max_tokens` alone only truncates a call after that
  # spend already happened.
  @request_option_keys ~w(
    base_url max_tokens max_retries receive_timeout temperature top_p reasoning_effort
  )a

  @doc """
  Generates one schema-constrained object.

  Returns `{:error, :missing_structured_object}` when the call succeeds but
  carries no object: an empty success would be validated as malformed output
  anyway, and this names the real problem.
  """
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

  @doc """
  Generates free text. Returns `{:error, :missing_text_response}` when the call
  succeeds but the response carries no text.
  """
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

  @doc """
  Embeds texts through an API-backed embedding endpoint.

  Two response shapes are handled because usage reporting is optional across
  endpoints: with counts, they are recorded; without, the vectors are still
  returned and the usage row simply shows zero tokens rather than a guess.
  """
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

  @doc """
  Reranks documents against a query, returning the endpoint's ranked results.
  """
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

  # An OpenAI-compatible endpoint is addressed as the OpenAI provider plus an
  # explicit base URL, which is how a self-hosted or proxied server is reached
  # without needing its own adapter. The nil base URL is dropped rather than
  # passed, so the library's own default applies when none is configured.
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

  # Every other provider is named directly, so adding support for one that the
  # underlying library already knows needs no code change here.
  defp model_spec(%Role{provider: provider, model: model}) do
    "#{provider}:#{model}"
  end

  # Builds the outbound request options: allowlisted configured values, then the
  # resolved credential, then per-call overrides last so a caller's explicit
  # timeout or temperature wins over the stored default.
  defp request_opts(%Role{options: options}, overrides) do
    configured =
      @request_option_keys
      |> Enum.reduce([], fn key, acc ->
        case Map.get(options, Atom.to_string(key)) do
          nil -> acc
          value -> [{key, normalize_option_value(key, value)} | acc]
        end
      end)

    configured
    |> maybe_put(:api_key, resolve_api_key(options))
    |> Keyword.merge(Keyword.take(overrides, @request_option_keys))
  end

  # Role options are always string-valued so they stay printable/exportable
  # regardless of source (see `Cartulary.Model.Config.Role`), but req_llm's
  # NimbleOptions schema validates `reasoning_effort` against a fixed atom
  # enum and rejects a string outright — every provider request would fail
  # this validation before making any call. Only some of req_llm's own
  # provider adapters (e.g. its OpenAI adapter, but not OpenRouter) tolerate a
  # string here, so the conversion must happen for every provider, not rely on
  # the adapter reached.
  defp normalize_option_value(:reasoning_effort, value) when is_binary(value) do
    String.to_existing_atom(value)
  end

  defp normalize_option_value(_key, value), do: value

  # Reads the credential at call time from the environment variable that the
  # role's `api_key_ref` names. Only the reference is ever persisted; the key
  # itself lives in the process environment and exists in memory only for the
  # duration of the request. A reference in any other form yields no key, so a
  # value accidentally pasted in place of a reference is not used as one.
  #
  # The application-level `:models` entry is the older single-key configuration
  # and still wins when set, so an existing deployment keeps working after roles
  # were introduced.
  defp resolve_api_key(options) do
    legacy = Application.get_env(:cartulary, :models, [])

    Keyword.get(legacy, :api_key) ||
      case Map.get(options, "api_key_ref") || Keyword.get(legacy, :api_key_ref) do
        "env:" <> variable -> System.get_env(variable)
        _other -> nil
      end
  end

  # A missing or blank credential is omitted entirely rather than sent as an
  # empty string, so an unauthenticated local endpoint works and a
  # misconfigured hosted one fails with a clear authentication error.
  defp maybe_put(keyword, _key, nil), do: keyword
  defp maybe_put(keyword, _key, ""), do: keyword
  defp maybe_put(keyword, key, value), do: Keyword.put(keyword, key, value)

  defp usage(value), do: ReqLLM.Usage.normalize(value || %{})

  # Embedding endpoints report their consumption as input tokens. Recording it
  # separately as embedding tokens keeps the ledger able to distinguish cheap
  # bulk embedding from generation spend, and output tokens are forced to zero
  # because an embedding produces none.
  defp embedding_usage(value) do
    normalized = usage(value)

    normalized
    |> Map.put(:embedding_tokens, Map.get(normalized, :input_tokens, 0) || 0)
    |> Map.put(:output_tokens, 0)
  end
end
