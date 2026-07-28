# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Observability do
  @moduledoc """
  Development observability setup.

  OpenTelemetry export is controlled by runtime configuration. This module only
  attaches instrumentation handlers and log correlation so Phoenix, Bandit,
  Ecto, Oban, and manual spans share one trace context.
  """

  require OpenTelemetry.Tracer, as: Tracer

  def setup do
    OpentelemetryLoggerMetadata.setup()
    setup_http()
    setup_phoenix()
    setup_ecto()
    setup_oban()
  end

  def with_span(category, span_name, fun) when is_function(fun, 0) do
    if span_enabled?(category) do
      Tracer.with_span span_name do
        fun.()
      end
    else
      fun.()
    end
  end

  def set_attribute(category, key, value) do
    if span_enabled?(category) do
      Tracer.set_attribute(key, value)
    end
  end

  def set_attributes(category, attributes) when is_map(attributes) do
    if span_enabled?(category) do
      Tracer.set_attributes(attributes)
    end
  end

  def span_enabled?(category) do
    category
    |> span_config_key()
    |> enabled?(true)
  end

  defp setup_http do
    if enabled?(:http_spans, true) do
      OpentelemetryBandit.setup(
        request_headers: ["x-request-id"],
        response_headers: ["x-request-id"]
      )
    end
  end

  defp setup_phoenix do
    if enabled?(:phoenix_spans, false) do
      OpentelemetryPhoenix.setup(adapter: :bandit)
    end
  end

  defp setup_ecto do
    if enabled?(:ecto_spans, false) do
      OpentelemetryEcto.setup([:cartulary, :repo], db_statement: db_statement_config())
    end
  end

  defp setup_oban do
    if enabled?(:oban_spans, true) do
      OpentelemetryOban.setup(
        job: [span_relationship: oban_span_relationship()],
        plugin: :disabled
      )
    end
  end

  defp db_statement_config do
    :cartulary
    |> Application.get_env(:observability, [])
    |> Keyword.get(:db_statement, :disabled)
  end

  defp oban_span_relationship do
    :cartulary
    |> Application.get_env(:observability, [])
    |> Keyword.get(:oban_span_relationship, :child)
  end

  defp enabled?(key, default) do
    :cartulary
    |> Application.get_env(:observability, [])
    |> Keyword.get(key, default)
  end

  defp span_config_key(:memory), do: :memory_spans
  defp span_config_key(:model), do: :model_spans
  defp span_config_key(:documents), do: :document_spans
  defp span_config_key(category), do: category
end
