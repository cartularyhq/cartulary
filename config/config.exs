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
    Cartulary.Knowledge,
    Cartulary.Governance,
    Cartulary.Model,
    Cartulary.Retrieval,
    Cartulary.Skills,
    Cartulary.Operations
  ],
  generators: [timestamp_type: :utc_datetime]

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
  fast: %{version: "poc-0", strategies: [:lexical, :salience_recency], deadline_ms: 250},
  balanced: %{
    version: "poc-0",
    strategies: [:lexical, :temporal, :salience_recency],
    deadline_ms: 750
  },
  thorough: %{
    version: "poc-0",
    strategies: [:lexical, :temporal, :salience_recency],
    deadline_ms: 1500
  }

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
