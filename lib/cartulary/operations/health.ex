# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Operations.Health do
  @moduledoc "Content-safe liveness and readiness checks for F10 operators."

  alias Cartulary.Repo

  @queue_states ~w(available scheduled retryable executing)

  def liveness do
    %{status: "ok", app: "cartulary", version: "f10-1"}
  end

  def readiness do
    checks = %{
      app: %{status: "ok"},
      database: database_check(),
      oban: oban_check(),
      queues: queue_check(),
      model_roles: model_roles_check()
    }

    status =
      if Enum.all?(checks, fn {_name, check} -> check.status == "ok" end),
        do: "ready",
        else: "not_ready"

    %{status: status, app: "cartulary", version: "f10-1", checks: checks}
  end

  def ready?(%{status: "ready"}), do: true
  def ready?(_result), do: false

  def emit_queue_metrics do
    case queue_check() do
      %{status: "ok", depths: depths} ->
        Enum.each(depths, fn {queue, states} ->
          Enum.each(states, fn {state, depth} ->
            :telemetry.execute(
              [:cartulary, :operations, :queue],
              %{depth: depth},
              %{queue: queue, state: state}
            )
          end)
        end)

      _error ->
        :ok
    end
  end

  defp database_check do
    case Ecto.Adapters.SQL.query(Repo, "SELECT 1", [], timeout: 2_000) do
      {:ok, _result} -> %{status: "ok"}
      {:error, error} -> %{status: "error", error_class: error_class(error)}
    end
  rescue
    error -> %{status: "error", error_class: error_class(error)}
  end

  defp oban_check do
    case Oban.whereis(Oban) do
      pid when is_pid(pid) -> %{status: "ok"}
      _other -> %{status: "error", error_class: "not_running"}
    end
  end

  # Static, parameterized readiness aggregate over the internal Oban table.
  # sobelow_skip ["SQL.Query"]
  defp queue_check do
    sql = """
    SELECT queue, state, count(*)
    FROM oban_jobs
    WHERE state = ANY($1)
    GROUP BY queue, state
    """

    case Ecto.Adapters.SQL.query(Repo, sql, [@queue_states], timeout: 2_000) do
      {:ok, %{rows: rows}} ->
        depths =
          Enum.reduce(rows, %{}, fn [queue, state, count], result ->
            Map.update(result, queue, %{state => count}, &Map.put(&1, state, count))
          end)

        %{status: "ok", depths: depths}

      {:error, error} ->
        %{status: "error", error_class: error_class(error)}
    end
  rescue
    error -> %{status: "error", error_class: error_class(error)}
  end

  defp model_roles_check do
    roles =
      :cartulary
      |> Application.fetch_env!(:model_roles)
      |> Map.new(fn {role, config} ->
        config = Map.new(config)

        {role,
         %{
           provider: Map.get(config, :provider),
           model: Map.get(config, :model),
           version: Map.get(config, :model_version)
         }}
      end)

    %{status: "ok", configured: roles}
  rescue
    error -> %{status: "error", error_class: error_class(error)}
  end

  defp error_class(%module{}), do: inspect(module)
end
