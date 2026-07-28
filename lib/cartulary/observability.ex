# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Observability do
  @moduledoc """
  Tracing seam: wires framework instrumentation together and gates the
  application's own spans by category.

  Whether traces leave the node at all is a separate, runtime decision. This
  module only attaches handlers and correlates logs, so that HTTP, database,
  background job, and hand-written spans all end up in the same trace instead
  of several disconnected ones. Nothing here changes what the system computes;
  turning every category off changes only what is observed.

  ## Content safety is absolute

  A span attribute is a place where content leaks, because traces are exported
  to whatever backend the operator configured and are retained long after the
  request. Only identifiers, counts, category and profile names, model and
  provider names, versions, timings, token counts, and error classes may be
  recorded. Never raw messages, prompts, questions, answers, statements,
  document text, connector cursors, API keys, Account keys, peer keys, or any
  restricted knowledge. This is the reason database statements are off by
  default: a SQL statement carries its parameters, and those parameters are
  content.

  ## Categories

  Callers pass a category rather than reading configuration, so a whole class
  of spans can be silenced without touching the code that emits them. An
  unrecognised category is enabled by default — a new span shows up rather than
  disappearing silently — so adding a category to the configuration mapping is
  how you make it switchable, not how you make it work.

  ## What a disabled category does and does not skip

  With a category off, the wrapped function still runs — only the span around
  it is skipped — and the attribute setters become no-ops. So wrapping work in
  a span never changes whether that work happens, which is the property that
  makes it safe to add spans anywhere. It also means an expensive value
  computed at the call site purely to be recorded is computed whether or not
  anything records it, so keep attribute expressions cheap.
  """

  require OpenTelemetry.Tracer, as: Tracer

  @doc """
  Attaches log correlation and the framework instrumentation handlers.

  Called once during application startup, before anything that could emit a
  span. Log metadata is correlated first so that log lines written during
  startup already carry trace ids.

  Each framework handler is attached only when its category is enabled, which
  is why disabling a category costs nothing at runtime: the handler is never
  attached rather than attached and ignored.
  """
  def setup do
    OpentelemetryLoggerMetadata.setup()
    setup_http()
    setup_phoenix()
    setup_ecto()
    setup_oban()
  end

  @doc """
  Runs `fun` inside a span named `span_name`, or runs it directly when
  `category` is disabled.

  `category` selects the configuration switch; `span_name` should be a stable,
  low-cardinality string, since a name built from a request value fragments
  traces and can itself leak content.

  Returns whatever `fun` returns, and lets exceptions propagate unchanged, so
  wrapping a call in a span can never alter its result or its failure
  behaviour.
  """
  def with_span(category, span_name, fun) when is_function(fun, 0) do
    if span_enabled?(category) do
      Tracer.with_span span_name do
        fun.()
      end
    else
      fun.()
    end
  end

  @doc """
  Records one attribute on the current span, or does nothing when `category` is
  disabled.

  Only content-safe values belong here: ids, counts, names, versions, timings,
  and error classes. Attaching an attribute outside an active span is a no-op
  rather than an error.
  """
  def set_attribute(category, key, value) do
    if span_enabled?(category) do
      Tracer.set_attribute(key, value)
    end
  end

  @doc """
  Records a map of attributes on the current span in one call, subject to the
  same content-safety rule and the same category gate as the single-attribute
  form.
  """
  def set_attributes(category, attributes) when is_map(attributes) do
    if span_enabled?(category) do
      Tracer.set_attributes(attributes)
    end
  end

  @doc """
  Whether spans for `category` are currently being recorded.

  Defaults to true for any category with no configuration entry, so a new span
  category is visible until someone deliberately turns it off.
  """
  def span_enabled?(category) do
    category
    |> span_config_key()
    |> enabled?(true)
  end

  # The server span is the root of every request trace. Only the request-id
  # header is captured in each direction — it is the correlation handle a
  # support conversation uses. Do not add the authorization header here.
  defp setup_http do
    if enabled?(:http_spans, true) do
      OpentelemetryBandit.setup(
        request_headers: ["x-request-id"],
        response_headers: ["x-request-id"]
      )
    end
  end

  # Adds route and controller naming on top of the raw server span. The runtime
  # configuration enables this category, so the `false` here only applies when
  # no observability configuration is present at all.
  defp setup_phoenix do
    if enabled?(:phoenix_spans, false) do
      OpentelemetryPhoenix.setup(adapter: :bandit)
    end
  end

  # Off by default: one span per query buries the workflow spans that actually
  # explain behaviour. Enable it for latency debugging, and note that including
  # the statement text also risks including its parameters.
  defp setup_ecto do
    if enabled?(:ecto_spans, false) do
      OpentelemetryEcto.setup([:cartulary, :repo], db_statement: db_statement_config())
    end
  end

  # Job spans are instrumented; the queue library's internal plugin spans are
  # not, because they are periodic housekeeping that would swamp the trace view
  # without explaining any request.
  defp setup_oban do
    if enabled?(:oban_spans, true) do
      OpentelemetryOban.setup(
        job: [span_relationship: oban_span_relationship()],
        plugin: :disabled
      )
    end
  end

  # Defaults to disabled: a SQL statement carries the values bound into it, and
  # those values are message content, statements, and identifiers.
  defp db_statement_config do
    :cartulary
    |> Application.get_env(:observability, [])
    |> Keyword.get(:db_statement, :disabled)
  end

  # How a background job's span relates to the request that enqueued it.
  # Defaulting to a child span keeps asynchronous extraction visible inside the
  # trace of the request that caused it, which is usually what someone
  # debugging ingest wants to see.
  defp oban_span_relationship do
    :cartulary
    |> Application.get_env(:observability, [])
    |> Keyword.get(:oban_span_relationship, :child)
  end

  # Each caller passes its own default, so a category is enabled or disabled by
  # the policy at its call site rather than by one global default here.
  defp enabled?(key, default) do
    :cartulary
    |> Application.get_env(:observability, [])
    |> Keyword.get(key, default)
  end

  # Maps a caller-facing category to its configuration key. The catch-all
  # returns the category unchanged, so a category with no mapping falls through
  # to the enabled-by-default branch: a new span type is visible immediately and
  # becomes switchable once a mapping and a configuration entry are added.
  defp span_config_key(:memory), do: :memory_spans
  defp span_config_key(:model), do: :model_spans
  defp span_config_key(:documents), do: :document_spans
  defp span_config_key(category), do: category
end
