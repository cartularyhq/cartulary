# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule CartularyWeb.Telemetry do
  @moduledoc """
  Supervises metric collection for the running node and declares the metric set that a
  reporter can export.

  Two separate things live here:

  - A **poller** child that periodically asks the system for numbers nothing else pushes —
    currently the Oban queue depths, which are a database fact rather than an event.
  - `metrics/0`, a **declaration** of which telemetry events are aggregated and how. These
    definitions do nothing on their own: a value is only recorded once some reporter attaches
    to them. No reporter is started by default, so on a stock node the events are emitted and
    dropped. Adding one (a console reporter, a Prometheus exporter, a dashboard) is what
    turns this list on.

  Everything declared here must stay content-safe. Metric tags become labels on exported
  series that operators and dashboards can read, so they may carry route patterns, queue
  names, job states, event names, and status classes — never message text, statements,
  prompts, answers, credentials, or per-subject identifiers. Tagging by a matched route
  pattern rather than the raw request path is deliberate: it keeps ids out of the labels and
  keeps series cardinality bounded.
  """

  use Supervisor

  import Telemetry.Metrics

  @doc """
  Starts the telemetry supervisor under the application's supervision tree.
  """
  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  # Children are independent: a crashing reporter should be restarted on its own without
  # resetting the poller, hence :one_for_one.
  @impl true
  def init(_arg) do
    children = [
      # 10_000 ms between polls: frequent enough to notice a queue backing up within a
      # deploy window, slow enough that the extra Oban count query is negligible load.
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
      # A reporter goes here when an operator wants these metrics exported, for example:
      # {Telemetry.Metrics.ConsoleReporter, metrics: metrics()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  The metric definitions a reporter attaches to.

  Returns a list of `Telemetry.Metrics` structs covering HTTP and channel timings, database
  timings, Oban queue depth, whole-Account export/import duration, and BEAM vitals. Calling
  this function records nothing; it only describes what should be aggregated.
  """
  def metrics do
    [
      # Phoenix request and channel timings. Framework events measure in native time units,
      # hence the {:native, :millisecond} conversion on each one. The :route tag is the
      # matched route pattern, so a path containing an id does not explode the label space.
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # Database timings. queue_time rising while query_time stays flat means the connection
      # pool is the bottleneck, not Postgres — worth separating before tuning either one.
      # The SQL text itself is never a metric tag.
      summary("cartulary.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("cartulary.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("cartulary.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("cartulary.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("cartulary.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      ),

      # Operations and Account-portability metrics.
      #
      # Queue depth is a gauge, not a running total: each poll reports the current count per
      # queue and job state, so last_value is the correct aggregation.
      last_value("cartulary.operations.queue.depth",
        tags: [:queue, :state],
        description: "Current Oban queue depth by queue and state"
      ),
      # Whole-Account archive export and import. These emitters already compute their
      # duration in milliseconds, so the unit pair is millisecond-to-millisecond — a no-op
      # conversion, unlike the native-time framework events above. Only the :ok/:error
      # status is tagged; Account ids and archive contents stay out of metrics.
      summary("cartulary.portability.export.duration",
        unit: {:millisecond, :millisecond},
        tags: [:status]
      ),
      summary("cartulary.portability.import.duration",
        unit: {:millisecond, :millisecond},
        tags: [:status]
      ),

      # BEAM vitals. Run-queue lengths separate CPU-bound scheduling pressure from IO-bound
      # pressure, which is the fastest way to tell a busy node from a blocked one.
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  # Functions the poller invokes on every tick. Queue depth has no natural event to hook —
  # nothing "happens" when jobs sit in the queue — so it must be sampled. The health module
  # stays silent when the database is unreachable rather than raising, which keeps a Postgres
  # blip from taking the poller (and with it every other periodic measurement) down.
  defp periodic_measurements do
    [
      {Cartulary.Operations.Health, :emit_queue_metrics, []}
    ]
  end
end
