# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Application do
  @moduledoc """
  Boots the node: validates configuration, then starts the supervision tree in a fixed order.

  Two things happen before any child starts, and both are deliberate. Runtime
  configuration is validated so a misconfigured node fails immediately with a
  message naming the offending setting, instead of half-starting and failing
  later against a database it should never have touched. Instrumentation
  handlers are attached next, so events from the repository, the queue, and the
  endpoint are traced from the first one they emit.

  ## The child order is a contract

  `:one_for_one` restarts a crashed child in place, but the *initial* order
  below encodes real dependencies:

  1. The embedded PostgreSQL manager, when the node supervises its own
     database. It must reach a listening server before the repository tries to
     connect and before migrations run — that is the whole reason it is first.
     In external-database mode this entry is simply absent; the release, the
     schema, and every guarantee are otherwise identical, because where
     Postgres lives is infrastructure, not behaviour.
  2. Telemetry, then the repository.
  3. The migration step. When automatic migration is switched on it blocks in
     its own `init/1` until the schema is current; when it is off the process
     starts and does nothing. It sits after the repository (it needs a
     connection) and before the web endpoint (no request may be served against
     a stale schema).
  4. Authentication, the rebuildable spend counters, the job supervisor,
     optional node discovery, and the PubSub and projection-cache processes the
     request path expects to be alive.
  5. The web endpoint last, so the node only accepts traffic once everything it
     depends on is up.

  Reordering these is not a cosmetic change: moving the endpoint earlier serves
  requests against an unmigrated database, and moving the database manager
  later leaves the repository connecting to nothing.
  """

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
          # Queues run on the Postgres engine in every deployment mode, driven by
          # the triggers declared on the Ash domains. There is no second broker
          # and no separate worker fleet to keep in sync.
          {Oban, oban_config()},
          {DNSCluster, query: Application.get_env(:cartulary, :dns_cluster_query) || :ignore},
          {Phoenix.PubSub, name: Cartulary.PubSub},
          Cartulary.Context.Cache,
          CartularyWeb.Endpoint
        ]

    opts = [strategy: :one_for_one, name: Cartulary.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Phoenix keeps endpoint settings in its own configuration store, so a
  # configuration reload has to be handed to the endpoint explicitly.
  @impl true
  def config_change(changed, _new, removed) do
    CartularyWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # Runs before the supervision tree is torn down, which is the only reliable
  # place to stop a self-supervised database. The manager process does not trap
  # exits, so the shutdown signal a supervisor sends would kill it without
  # running its own cleanup, leaving an orphaned PostgreSQL server behind. The
  # `whereis` guard covers the case where that process already died.
  @impl true
  def prep_stop(state) do
    if Cartulary.RuntimeConfig.pg0?() and Process.whereis(Cartulary.Pg0) do
      Cartulary.Pg0.stop_database()
    end

    state
  end

  @doc """
  Builds the Oban configuration this node starts its Oban supervisor with.

  `AshOban.config/2` forces `peer: false` onto the base Oban config whenever `:plugins`
  is not already a non-empty list — which it deliberately is not, per the comment on
  `config :cartulary, Oban`. Oban then folds that literal `false` into
  `{Oban.Peers.Isolated, [leader?: false]}`: a peer that can never win leadership, on any
  node, ever. Oban's stager is core supervision infrastructure in this Oban version (not
  a plugin, so the empty plugin list does not remove it), but it still only promotes
  `scheduled`/`retryable` jobs past their `scheduled_at` time while its node holds
  leadership. Without a winnable leadership, a job that fails once and is scheduled for
  backoff retry never gets a second attempt — nothing raises, it simply never comes back.
  Restoring the ordinary database-backed peer here, after `AshOban.config/2` has already
  run, keeps every other consequence of the empty plugin list (no Cron, no Pruner) while
  letting this node actually become leader and stage its own delayed jobs.

  Public so regression tests can assert on the merged config without starting a
  supervision tree.
  """
  @spec oban_config() :: keyword()
  def oban_config do
    Keyword.put(
      AshOban.config(
        Application.fetch_env!(:cartulary, :ash_domains),
        Application.fetch_env!(:cartulary, Oban)
      ),
      :peer,
      Oban.Peers.Database
    )
  end
end
