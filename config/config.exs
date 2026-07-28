# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :ash, :missed_notifications, :ignore

config :cartulary,
  ecto_repos: [Cartulary.Repo],
  ash_domains: [
    Cartulary.Accounts,
    Cartulary.Topology,
    Cartulary.Observations,
    Cartulary.Documents,
    Cartulary.Knowledge,
    Cartulary.Governance,
    Cartulary.Model,
    Cartulary.Retrieval,
    Cartulary.Skills,
    Cartulary.Operations
  ],
  generators: [timestamp_type: :utc_datetime]

config :cartulary, Cartulary.Repo, types: Cartulary.PostgrexTypes

config :cartulary, :identity,
  account_key: "local",
  account_name: "Local Cartulary"

config :cartulary, Oban,
  engine: Oban.Engines.Basic,
  repo: Cartulary.Repo,
  queues: [
    ingest: 10,
    dream: 2,
    lifecycle: 2,
    projection: 2,
    governance: 2,
    connector: 2,
    portability: 1,
    reconciler: 1
  ],
  plugins: false

config :ash_oban,
  authorize?: true,
  shared_context: [:job]

config :cartulary, :retrieval_profiles,
  fast: %{
    version: "f7-1",
    strategies: [:semantic, :salience_recency],
    weights: %{semantic: 1.0, salience_recency: 0.8},
    rerank: false,
    deadline_ms: 100
  },
  balanced: %{
    version: "f7-1",
    strategies: [:semantic, :lexical, :temporal, :entity_match],
    weights: %{semantic: 1.0, lexical: 1.0, temporal: 0.7, entity_match: 0.9},
    rerank: false,
    deadline_ms: 300
  },
  thorough: %{
    version: "f7-1",
    strategies: [
      :semantic,
      :lexical,
      :temporal,
      :salience_recency,
      :entity_match,
      :relation_expand
    ],
    weights: %{
      semantic: 1.0,
      lexical: 1.0,
      temporal: 0.7,
      salience_recency: 0.8,
      entity_match: 0.9,
      relation_expand: 0.6
    },
    rerank: true,
    deadline_ms: 1500
  },
  enabled_strategies: [
    :semantic,
    :lexical,
    :temporal,
    :salience_recency,
    :entity_match,
    :relation_expand
  ],
  rrf_k: 60,
  max_candidates: 50,
  rerank_head: 20,
  projection_compaction_every: 20,
  context_budget_chars: 8_000

config :cartulary, :governance,
  attach_deadline_ms: 15,
  relevance_floor: 0.62,
  max_per_session: 3,
  max_per_day: 10,
  max_attempts: 2,
  attempt_cooldown_hours: 48,
  answer_window_turns: 6

config :cartulary, :model_layer, max_repairs: 2

config :ex_aws, http_client: ExAws.Request.Req

config :cartulary, :documents,
  blob_adapter: Cartulary.Documents.BlobStore.Local,
  blob_root: Path.join(System.tmp_dir!(), "cartulary-blobs"),
  chunk_size: 1_200,
  chunk_overlap: 160,
  max_extract_length: 500_000,
  connector_adapters: %{}

config :cartulary, :model_roles,
  embedder: %{
    provider: "ortex",
    model: "BAAI/bge-small-en-v1.5",
    model_version: "onnx-1",
    prompt_version: "none",
    pipeline_version: "f5-1",
    embedding_dimensions: 384,
    options: %{}
  },
  ingest_extractor: %{
    provider: "deterministic",
    model: "local-structured-fallback",
    model_version: "1",
    prompt_version: "extract-1",
    pipeline_version: "f5-1",
    options: %{}
  },
  dream_reasoner: %{
    provider: "deterministic",
    model: "local-structured-fallback",
    model_version: "1",
    prompt_version: "reason-1",
    pipeline_version: "f5-1",
    options: %{}
  },
  dialectic_agent: %{
    provider: "deterministic",
    model: "local-structured-fallback",
    model_version: "1",
    prompt_version: "dialectic-1",
    pipeline_version: "f5-1",
    options: %{}
  }

# Compatibility key for pre-F5 tests and local tasks. Runtime configuration
# stores only a secret reference; no credential is copied into role config.
config :cartulary, :models, api_key: nil, api_key_ref: "env:OPENROUTER_API_KEY"

# Configure the endpoint
config :cartulary, CartularyWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: CartularyWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Cartulary.PubSub,
  live_view: [signing_salt: "GplcMfTh"]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :trace_id, :span_id]

config :opentelemetry, traces_exporter: :none

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :phoenix, :filter_parameters, [
  "answer",
  "api_key",
  "authorization",
  "content",
  "messages",
  "password",
  "prompt",
  "question",
  "query",
  "secret",
  "statement",
  "token"
]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
