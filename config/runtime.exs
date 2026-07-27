# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

import Config
import Dotenvy

env = source!([".env", System.get_env()])
env_get = fn key, default -> Map.get(env, key, default) end

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

config :cartulary, :models,
  base_url: env_get.("CARTULARY_OPENAI_COMPAT_BASE_URL", "https://openrouter.ai/api/v1"),
  api_key: env_get.("OPENROUTER_API_KEY", nil),
  api_key_env: "OPENROUTER_API_KEY",
  ingest: env_get.("CARTULARY_MODEL_INGEST", "openai/gpt-oss-120b"),
  dream: env_get.("CARTULARY_MODEL_DREAM", "openai/gpt-oss-120b"),
  ask: env_get.("CARTULARY_MODEL_ASK", "openai/gpt-oss-120b")

if database_url = env_get.("DATABASE_URL", nil) do
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
