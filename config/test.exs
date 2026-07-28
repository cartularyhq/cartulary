# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :cartulary, Cartulary.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "cartulary_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :cartulary, CartularyWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "+kva5XkTTwZ6ikuEVRv2mqPLh23Lfu3ht8EDoqqwb1tYR2ohmjlXZlwi9eEuHdpi",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

config :cartulary, Oban, testing: :manual

# Tests must remain deterministic even when the developer shell has a live
# model credential. The runtime model config deliberately clears that key.
config :cartulary, :governance, attach_deadline_ms: 1_000

# SQL sandbox owns one shared connection per non-async test. Production keeps
# true Task fan-out; tests execute the same strategy contracts serially so four
# tasks do not contend for the single sandbox connection.
config :cartulary, :retrieval_concurrency, false

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
