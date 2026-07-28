# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

import Config
import Dotenvy

env = source!([".env", System.get_env()])
env_get = fn key, default -> Map.get(env, key, default) end

env_true? = fn key ->
  String.downcase(env_get.(key, "false")) in ~w(true 1 yes on)
end

env_bool = fn key, default ->
  value = if default, do: "true", else: "false"
  String.downcase(env_get.(key, value)) in ~w(true 1 yes on)
end

env_headers = fn key ->
  key
  |> env_get.("")
  |> String.split(",", trim: true)
  |> Enum.flat_map(fn header ->
    case String.split(header, "=", parts: 2) do
      [name, value] -> [{String.trim(name), String.trim(value)}]
      _ -> []
    end
  end)
end

env_protocol = fn key, default ->
  case env_get.(key, default) do
    "grpc" -> :grpc
    "http_protobuf" -> :http_protobuf
    _ -> :http_protobuf
  end
end

env_float = fn key, default ->
  case Float.parse(env_get.(key, default)) do
    {value, ""} -> value
    _ -> String.to_float(default)
  end
end

env_integer = fn key, default ->
  case Integer.parse(env_get.(key, default)) do
    {value, ""} -> value
    _other -> String.to_integer(default)
  end
end

env_sampler = fn ->
  sampler = env_get.("OTEL_TRACES_SAMPLER", "parentbased_always_on")

  case sampler do
    "always_on" ->
      :always_on

    "always_off" ->
      :always_off

    "traceidratio" ->
      {:trace_id_ratio_based, env_float.("OTEL_TRACES_SAMPLER_ARG", "1.0")}

    "parentbased_always_off" ->
      {:parent_based, %{root: :always_off}}

    "parentbased_traceidratio" ->
      {:parent_based,
       %{root: {:trace_id_ratio_based, env_float.("OTEL_TRACES_SAMPLER_ARG", "1.0")}}}

    _ ->
      {:parent_based, %{root: :always_on}}
  end
end

env_oban_span_relationship = fn ->
  case env_get.("CARTULARY_OTEL_OBAN_SPAN_RELATIONSHIP", "child") do
    "link" -> :link
    "none" -> :none
    _ -> :child
  end
end

env_otlp_config = fn ->
  config = [
    otlp_protocol: env_protocol.("OTEL_EXPORTER_OTLP_PROTOCOL", "http_protobuf"),
    otlp_traces_protocol: env_protocol.("OTEL_EXPORTER_OTLP_TRACES_PROTOCOL", "http_protobuf"),
    otlp_endpoint: env_get.("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4318"),
    otlp_headers: env_headers.("OTEL_EXPORTER_OTLP_HEADERS"),
    otlp_traces_headers: env_headers.("OTEL_EXPORTER_OTLP_TRACES_HEADERS")
  ]

  case env_get.("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", nil) do
    nil -> config
    endpoint -> Keyword.put(config, :otlp_traces_endpoint, endpoint)
  end
end

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/cartulary start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :cartulary, CartularyWeb.Endpoint, server: true
end

config :cartulary, CartularyWeb.Endpoint,
  http: [port: String.to_integer(env_get.("PORT", "4000"))]

auth_signing_secret =
  case env_get.("CARTULARY_AUTH_SIGNING_SECRET", nil) do
    secret when is_binary(secret) and byte_size(secret) >= 64 ->
      secret

    _missing_or_short ->
      if config_env() == :prod do
        raise """
        environment variable CARTULARY_AUTH_SIGNING_SECRET must contain at least
        64 bytes. Generate an independent random secret.
        """
      else
        :cartulary
        |> Application.fetch_env!(CartularyWeb.Endpoint)
        |> Keyword.fetch!(:secret_key_base)
      end
  end

config :cartulary, :identity,
  account_key: env_get.("CARTULARY_FREE_ACCOUNT_KEY", "local"),
  account_name: env_get.("CARTULARY_FREE_ACCOUNT_NAME", "Local Cartulary"),
  signing_secret: auth_signing_secret

model_api_key = if(config_env() == :test, do: nil, else: env_get.("OPENROUTER_API_KEY", nil))
requested_provider = env_get.("CARTULARY_MODEL_PROVIDER", "openrouter")
local_fallback? = env_bool.("CARTULARY_MODEL_LOCAL_FALLBACK", config_env() != :prod)

generation_provider =
  if requested_provider == "openrouter" and model_api_key in [nil, ""] and local_fallback? do
    "deterministic"
  else
    requested_provider
  end

generation_model = fn role_key, default ->
  if generation_provider == "deterministic" do
    "local-structured-fallback"
  else
    env_get.(role_key, default)
  end
end

generation_version =
  if generation_provider == "deterministic",
    do: "1",
    else: env_get.("CARTULARY_MODEL_VERSION", "unversioned")

generation_options = %{
  "api_key_ref" => "env:OPENROUTER_API_KEY",
  "base_url" => env_get.("CARTULARY_OPENAI_COMPAT_BASE_URL", "https://openrouter.ai/api/v1")
}

config :cartulary, :model_roles,
  embedder: %{
    provider: env_get.("CARTULARY_EMBEDDING_PROVIDER", "ortex"),
    model: env_get.("CARTULARY_EMBEDDING_MODEL", "BAAI/bge-small-en-v1.5"),
    model_version: env_get.("CARTULARY_EMBEDDING_VERSION", "onnx-1"),
    prompt_version: "none",
    pipeline_version: "f5-1",
    embedding_dimensions: env_integer.("CARTULARY_EMBEDDING_DIMENSIONS", "384"),
    options: %{
      "api_key_ref" => "env:CARTULARY_EMBEDDING_API_KEY",
      "base_url" => env_get.("CARTULARY_EMBEDDING_BASE_URL", nil),
      "model_path" => env_get.("CARTULARY_ORTEX_MODEL_PATH", nil),
      "tokenizer_path" => env_get.("CARTULARY_ORTEX_TOKENIZER_PATH", nil),
      "pooling" => env_get.("CARTULARY_ORTEX_POOLING", "cls"),
      "execution_providers" =>
        env_get.("CARTULARY_ORTEX_EXECUTION_PROVIDERS", "cpu")
        |> String.split(",", trim: true)
    }
  },
  ingest_extractor: %{
    provider: generation_provider,
    model: generation_model.("CARTULARY_MODEL_INGEST", "openai/gpt-oss-120b"),
    model_version: generation_version,
    prompt_version: "extract-1",
    pipeline_version: "f5-1",
    options: generation_options
  },
  dream_reasoner: %{
    provider: generation_provider,
    model: generation_model.("CARTULARY_MODEL_DREAM", "openai/gpt-oss-120b"),
    model_version: generation_version,
    prompt_version: "reason-1",
    pipeline_version: "f5-1",
    options: generation_options
  },
  dialectic_agent: %{
    provider: generation_provider,
    model: generation_model.("CARTULARY_MODEL_ASK", "openai/gpt-oss-120b"),
    model_version: generation_version,
    prompt_version: "dialectic-1",
    pipeline_version: "f5-1",
    options: generation_options
  }

retrieval_strategy_names = %{
  "semantic" => :semantic,
  "lexical" => :lexical,
  "temporal" => :temporal,
  "salience_recency" => :salience_recency,
  "entity_match" => :entity_match,
  "relation_expand" => :relation_expand
}

retrieval_profiles = Application.fetch_env!(:cartulary, :retrieval_profiles)

enabled_retrieval_strategies =
  "CARTULARY_RETRIEVAL_ENABLED_STRATEGIES"
  |> env_get.(
    retrieval_profiles
    |> Keyword.fetch!(:enabled_strategies)
    |> Enum.map_join(",", &Atom.to_string/1)
  )
  |> String.split(",", trim: true)
  |> Enum.map(fn name ->
    Map.get(retrieval_strategy_names, String.trim(name)) ||
      raise "unsupported retrieval strategy: #{inspect(name)}"
  end)
  |> Enum.uniq()

retrieval_profiles =
  retrieval_profiles
  |> Keyword.put(:enabled_strategies, enabled_retrieval_strategies)
  |> Keyword.update!(
    :fast,
    &Map.put(
      &1,
      :deadline_ms,
      env_integer.("CARTULARY_RETRIEVAL_FAST_DEADLINE_MS", Integer.to_string(&1.deadline_ms))
    )
  )
  |> Keyword.update!(
    :balanced,
    &Map.put(
      &1,
      :deadline_ms,
      env_integer.(
        "CARTULARY_RETRIEVAL_BALANCED_DEADLINE_MS",
        Integer.to_string(&1.deadline_ms)
      )
    )
  )
  |> Keyword.update!(
    :thorough,
    &Map.put(
      &1,
      :deadline_ms,
      env_integer.(
        "CARTULARY_RETRIEVAL_THOROUGH_DEADLINE_MS",
        Integer.to_string(&1.deadline_ms)
      )
    )
  )

config :cartulary, :retrieval_profiles, retrieval_profiles

config :cartulary, :models,
  base_url: generation_options["base_url"],
  api_key: nil,
  api_key_ref: "env:OPENROUTER_API_KEY"

blob_adapter =
  case env_get.("CARTULARY_BLOB_ADAPTER", "local") do
    "local" -> Cartulary.Documents.BlobStore.Local
    "s3" -> Cartulary.Documents.BlobStore.S3
    invalid -> raise "unsupported CARTULARY_BLOB_ADAPTER: #{inspect(invalid)}"
  end

default_blob_root =
  if config_env() == :prod,
    do: "/var/lib/cartulary/blobs",
    else: Path.join(System.tmp_dir!(), "cartulary-blobs-#{config_env()}")

config :cartulary, :documents,
  blob_adapter: blob_adapter,
  blob_root: env_get.("CARTULARY_BLOB_ROOT", default_blob_root),
  s3_bucket: env_get.("CARTULARY_S3_BUCKET", nil),
  s3_prefix: env_get.("CARTULARY_S3_PREFIX", "cartulary"),
  chunk_size: env_integer.("CARTULARY_DOCUMENT_CHUNK_SIZE", "1200"),
  chunk_overlap: env_integer.("CARTULARY_DOCUMENT_CHUNK_OVERLAP", "160"),
  max_extract_length: env_integer.("CARTULARY_DOCUMENT_MAX_EXTRACT_LENGTH", "500000"),
  connector_adapters: %{}

config :ex_aws,
  http_client: ExAws.Request.Req,
  region: env_get.("AWS_REGION", "us-east-1")

case env_get.("CARTULARY_S3_HOST", nil) do
  host when is_binary(host) and host != "" ->
    config :ex_aws, :s3,
      scheme: env_get.("CARTULARY_S3_SCHEME", "https://"),
      host: host,
      port: env_integer.("CARTULARY_S3_PORT", "443")

  _unset ->
    :ok
end

otel_db_statement =
  if env_true?.("CARTULARY_OTEL_DB_STATEMENT_ENABLED"), do: :enabled, else: :disabled

config :cartulary, :observability,
  db_statement: otel_db_statement,
  http_spans: env_bool.("CARTULARY_OTEL_HTTP_SPANS_ENABLED", true),
  phoenix_spans: env_bool.("CARTULARY_OTEL_PHOENIX_SPANS_ENABLED", true),
  ecto_spans: env_bool.("CARTULARY_OTEL_ECTO_SPANS_ENABLED", false),
  oban_spans: env_bool.("CARTULARY_OTEL_OBAN_SPANS_ENABLED", true),
  oban_span_relationship: env_oban_span_relationship.(),
  memory_spans: env_bool.("CARTULARY_OTEL_MEMORY_SPANS_ENABLED", true),
  model_spans: env_bool.("CARTULARY_OTEL_MODEL_SPANS_ENABLED", true),
  document_spans: env_bool.("CARTULARY_OTEL_DOCUMENT_SPANS_ENABLED", true)

config :opentelemetry,
  resource: %{
    :service => %{
      name: env_get.("OTEL_SERVICE_NAME", "cartulary-dev"),
      namespace: "cartulary"
    },
    :deployment => %{
      environment: env_get.("CARTULARY_ENVIRONMENT", "development")
    },
    "cartulary.experiment.name" => env_get.("CARTULARY_EXPERIMENT_NAME", "local-dev"),
    "cartulary.experiment.run_id" => env_get.("CARTULARY_EXPERIMENT_RUN_ID", "manual"),
    "cartulary.retrieval.variant" => env_get.("CARTULARY_RETRIEVAL_VARIANT", "poc-baseline")
  },
  sampler: env_sampler.()

if env_true?.("CARTULARY_OTEL_ENABLED") do
  config :opentelemetry,
    span_processor: :batch,
    traces_exporter: :otlp

  config :opentelemetry_exporter, env_otlp_config.()
else
  config :opentelemetry, traces_exporter: :none
end

# A developer's .env normally points at cartulary_dev and must not override the
# sandboxed database from config/test.exs. CI may still opt into a test database
# URL by exporting DATABASE_URL explicitly.
database_url =
  if config_env() == :test do
    System.get_env("DATABASE_URL")
  else
    env_get.("DATABASE_URL", nil)
  end

if database_url do
  config :cartulary, Cartulary.Repo,
    url: database_url,
    pool_size: String.to_integer(env_get.("POOL_SIZE", "10"))
end

if config_env() == :prod do
  database_url =
    env_get.("DATABASE_URL", nil) ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if env_get.("ECTO_IPV6", nil) in ~w(true 1), do: [:inet6], else: []

  config :cartulary, Cartulary.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(env_get.("POOL_SIZE", "10")),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    env_get.("SECRET_KEY_BASE", nil) ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = env_get.("PHX_HOST", "example.com")

  config :cartulary, :dns_cluster_query, env_get.("DNS_CLUSTER_QUERY", nil)

  config :cartulary, CartularyWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :cartulary, CartularyWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :cartulary, CartularyWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
