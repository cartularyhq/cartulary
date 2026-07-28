# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Cartulary.RuntimeConfig.validate!()
    Cartulary.Observability.setup()

    infrastructure_children =
      if Cartulary.RuntimeConfig.pg0?() do
        [Cartulary.Pg0]
      else
        []
      end

    children =
      infrastructure_children ++
        [
          CartularyWeb.Telemetry,
          Cartulary.Repo,
          Cartulary.Release.Migrator,
          {AshAuthentication.Supervisor, otp_app: :cartulary},
          Cartulary.Operations.BudgetCounter,
          {Oban,
           AshOban.config(
             Application.fetch_env!(:cartulary, :ash_domains),
             Application.fetch_env!(:cartulary, Oban)
           )},
          {DNSCluster, query: Application.get_env(:cartulary, :dns_cluster_query) || :ignore},
          {Phoenix.PubSub, name: Cartulary.PubSub},
          Cartulary.Context.Cache,
          # Start a worker by calling: Cartulary.Worker.start_link(arg)
          # {Cartulary.Worker, arg},
          # Start to serve requests, typically the last entry
          CartularyWeb.Endpoint
        ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Cartulary.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    CartularyWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  @impl true
  def prep_stop(state) do
    if Cartulary.RuntimeConfig.pg0?() and Process.whereis(Cartulary.Pg0) do
      Cartulary.Pg0.stop_database()
    end

    state
  end
end
