<!-- SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0 -->

# Development Observability

Cartulary development uses OpenTelemetry for traces, ordinary Logger output for
logs, Phoenix/Ecto/Oban telemetry for framework events, and the eval reports for
quality comparison. The local path is intentionally vendor-neutral: the app
exports OTLP to a local OpenTelemetry Collector, and the collector can fan traces
out to Jaeger, debug logs, Prometheus metrics, and optionally Langfuse.

This is a development setup, not the final production observability design from
`AD-OBS-*`. Keep it content-safe: do not record raw messages, prompts, answers,
API keys, account keys, peer keys, or restricted knowledge in span attributes or
logs.

## What Is Wired

- OpenTelemetry SDK/exporter dependencies are installed and disabled by default.
- `CARTULARY_OTEL_ENABLED=true` enables batch OTLP/HTTP trace export.
- Span categories are configurable. The default development shape enables HTTP
  request spans, Phoenix route naming, manual memory/model spans, and Oban job
  spans. Ecto deep-detail spans are opt-in because they add many low-level
  traces.
- Logger metadata includes `request_id`, `trace_id`, and `span_id`.
- Every HTTP response includes `x-trace-id`; when an active OTel span exists it
  also includes `x-span-id`. If the caller supplies a W3C `traceparent`, the
  response keeps that trace id. Otherwise the request gets a new trace id.
- Manual workflow spans are emitted for:
  - `cartulary.memory.ingest_message`
  - `cartulary.memory.extract_message`
  - `cartulary.memory.query_knowledge`
  - `cartulary.memory.search`
  - `cartulary.memory.ask`
  - `cartulary.memory.get_context`
  - `cartulary.model.chat`
  - `cartulary.model.structured`
  - `cartulary.model.embed`
  - `cartulary.model.rerank`
  - `cartulary.documents.process_version`
  - `cartulary.documents.sync_connector`
- Model-layer spans include safe GenAI-style attributes such as operation,
  role, provider/model/version, duration, and input/output/embedding token
  usage. The append-only `UsageEvent` Ash resource is the exact ledger; OTel
  remains a sampled diagnostic mirror.
- Document spans include safe identifiers and measures such as version id,
  parser, byte/chunk/knowledge counts, connector id, item count, and duration.
  They never include blob bytes, extracted text, connector cursors, source
  metadata, or statements.

## Start The Local Stack

Start the collector, Jaeger, and Prometheus:

```bash
docker compose -f dev/observability/docker-compose.yml up
```

Enable app export in `.env`:

```bash
CARTULARY_OTEL_ENABLED=true
OTEL_SERVICE_NAME=cartulary-dev
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:14318
CARTULARY_EXPERIMENT_NAME=local-dev
CARTULARY_EXPERIMENT_RUN_ID=manual
CARTULARY_RETRIEVAL_VARIANT=poc-baseline

CARTULARY_OTEL_HTTP_SPANS_ENABLED=true
CARTULARY_OTEL_PHOENIX_SPANS_ENABLED=true
CARTULARY_OTEL_MEMORY_SPANS_ENABLED=true
CARTULARY_OTEL_MODEL_SPANS_ENABLED=true
CARTULARY_OTEL_DOCUMENT_SPANS_ENABLED=true
CARTULARY_OTEL_OBAN_SPANS_ENABLED=true
CARTULARY_OTEL_OBAN_SPAN_RELATIONSHIP=child
CARTULARY_OTEL_ECTO_SPANS_ENABLED=false
```

`CARTULARY_RETRIEVAL_VARIANT=poc-baseline` repeats the current default value in
`config/runtime.exs`. That label is historical and kept for comparability with
recorded runs; its rename is tracked in `specs/roadmap/beta-roadmap.md`.

The collector receives OTLP/HTTP from the host on port `14318` and forwards it
to the standard container port `4318`. Override `CARTULARY_OTEL_HTTP_PORT`
before running Compose if your machine needs a different host port.

Then run the app or evals normally:

```bash
mix phx.server
mix cartulary.eval.smoke --profile balanced --account eval-observability
mix cartulary.eval.benchmark \
  --dataset test/fixtures/eval/cartulary-smoke.json \
  --benchmark cartulary \
  --profile balanced \
  --account eval-observability \
  --run-id otel-local \
  --no-model
```

## Where To Watch

| Need | Place | URL or command |
| --- | --- | --- |
| Request and app logs | Terminal running `mix phx.server` | Look for `request_id`, `trace_id`, `span_id` metadata. |
| Current request trace | HTTP response headers | Copy `x-trace-id` from any API response and search that trace id in Jaeger. |
| Collector intake/export | Collector logs | `docker compose -f dev/observability/docker-compose.yml logs -f otel-collector` |
| Traces | Jaeger | `http://localhost:16686`, service `cartulary-dev` |
| Collector and exported metrics | Prometheus | `http://localhost:9090`, scrape jobs `otel-collector` |
| Eval reports | Repository files or chosen output path | `specs/eval/results/`, `specs/eval/minimal-benchmark-results.md`, or `--output ...` |
| Database behavior | Ecto spans in Jaeger | Set `CARTULARY_OTEL_ECTO_SPANS_ENABLED=true`, then look for `cartulary.repo.query:*` spans under request/eval traces. |
| Background jobs | Oban spans in Jaeger | Look for extraction job spans once async paths are exercised. |
| Model calls | `cartulary.model.*` spans and `usage_events` | Filter traces by `cartulary.model.role`, provider, and `gen_ai.request.model`; use the database ledger for exact totals. |

## Span Controls

Use these flags to tune Jaeger noise for a given debugging session:

| Setting | Default | Effect |
| --- | --- | --- |
| `CARTULARY_OTEL_HTTP_SPANS_ENABLED` | `true` | One server trace per HTTP request. |
| `CARTULARY_OTEL_MEMORY_SPANS_ENABLED` | `true` | Manual memory workflow spans and safe retrieval attributes. |
| `CARTULARY_OTEL_MODEL_SPANS_ENABLED` | `true` | Model call spans and token counts, without prompt or answer text. |
| `CARTULARY_OTEL_DOCUMENT_SPANS_ENABLED` | `true` | Document parsing, chunking, extraction, and connector spans with content-safe counts and identifiers. |
| `CARTULARY_OTEL_OBAN_SPANS_ENABLED` | `true` | Background extraction job spans. |
| `CARTULARY_OTEL_OBAN_SPAN_RELATIONSHIP` | `child` | `child` keeps queued jobs in the request trace; `link` creates a separate linked trace; `none` disables propagation. |
| `CARTULARY_OTEL_PHOENIX_SPANS_ENABLED` | `true` | Phoenix route/controller span naming and framework context. |
| `CARTULARY_OTEL_ECTO_SPANS_ENABLED` | `false` | Extra database spans for SQL latency debugging. |
| `CARTULARY_OTEL_DB_STATEMENT_ENABLED` | `false` | Adds SQL statements to Ecto spans; keep disabled unless using scrubbed local data. |

## What To Measure

Measure both product quality and system behavior. A change that improves answer
quality but destroys latency, abstention, or cost visibility is not done.

| Area | Signals |
| --- | --- |
| Ingest | message content length, sync vs async extraction, extraction item count, raw write latency, provider failure behavior |
| Documents | version byte count, parser, chunk/knowledge counts, hash no-op count, tombstones, connector page duration, retry behavior |
| Pipeline | Oban queue latency, retries, job duration, dream-time budget use, revalidation/expiry sweeps once implemented |
| Retrieval | profile, profile version, strategy count, candidate count, latency, contributed strategies, dropped strategies, per-scope index coverage on projection refresh |
| Context | knowledge count, projection/cache hit, fast-fallback flag, no reasoning-model spans under normal `get_context` |
| Ask | candidate count, model used, abstention flag, citation correctness from eval report, latency |
| Model | operation, role, provider/model/version, prompt/pipeline version, input/output/embedding tokens, duration, error rate, repair attempt, retry behavior |
| Database | query time, queue time, transaction failures, migration/index behavior |
| Governance | gate decisions, validation queue age, consent requirement failures, audit/history coverage once implemented |
| Portability | export/import duration, resource count, rebuild duration, audit hash-chain verification outcome |
| Evaluation | exact match, expected containment, token-F1, abstention correctness, citation hit/recall, BEAM degradation curve, profile version |

## Experiment Discipline

For every retrieval, model, gate, or projection experiment:

1. Set `CARTULARY_EXPERIMENT_NAME` to the experiment family.
2. Set `CARTULARY_EXPERIMENT_RUN_ID` to the run id used in eval output.
3. Set `CARTULARY_RETRIEVAL_VARIANT` to the strategy/profile variant under test.
4. Run one deterministic baseline with `--no-model`.
5. Run the live-model path only after the deterministic baseline is recorded.
6. Keep the eval JSON report, trace time window, model role versions, profile
   version, deadline setting, and dataset together in the PR evidence.

Published or PR-visible quality numbers must cite the retrieval profile version,
model role versions, dataset, deadline setting, and date.

## Langfuse

Langfuse is optional. Use it when comparing LLM-heavy behavior, prompt/model
changes, or experiment runs that benefit from an LLM-native trace UI.

Official Langfuse OTLP guidance:

- `https://langfuse.com/integrations/native/opentelemetry`
- `https://langfuse.com/docs/observability/overview`

Langfuse accepts OTLP over HTTP on `/api/public/otel`; gRPC is not supported for
that endpoint. For real-time ingestion on the v4 data model, send the
`x-langfuse-ingestion-version: 4` header.

Create the Basic Auth value from the Langfuse public and secret keys:

```bash
printf '%s' 'pk-lf-...:sk-lf-...' | base64
```

Start the Langfuse-forwarding collector:

```bash
LANGFUSE_OTLP_ENDPOINT=https://cloud.langfuse.com/api/public/otel \
LANGFUSE_OTLP_AUTHORIZATION='Basic <base64-public-key-colon-secret-key>' \
docker compose -f dev/observability/docker-compose.langfuse.yml up
```

Keep the app pointed at the local collector:

```bash
CARTULARY_OTEL_ENABLED=true
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:14318
```

Direct app-to-Langfuse export is also possible, but it skips local Jaeger and
collector debug logs. Use it only when the collector is not needed:

```bash
CARTULARY_OTEL_ENABLED=true
OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=https://cloud.langfuse.com/api/public/otel/v1/traces
OTEL_EXPORTER_OTLP_TRACES_HEADERS=Authorization=Basic <base64-public-key-colon-secret-key>,x-langfuse-ingestion-version=4
```

## Safety Defaults

- `CARTULARY_OTEL_ENABLED=false` by default.
- Ecto spans are disabled by default to keep Jaeger focused on workflow traces
  instead of many standalone database traces.
- `CARTULARY_OTEL_DB_STATEMENT_ENABLED=false` by default because SQL statements
  can include sensitive values.
- Dev Repo query logging is disabled by default for the same reason; use Ecto
  spans for query timing and table-level source metadata.
- Phoenix parameter filtering redacts credential fields and content-bearing
  fields such as `content`, `messages`, `prompt`, `question`, `query`,
  `statement`, and `answer`.
- Manual spans record counts, flags, model names/versions, and token counts, not raw
  content.
- Document spans record IDs, parser names, hashes, counts, and durations, not
  blobs, extracted text, source metadata, connector cursors, or statements.
- `cartulary.model.*` spans and `UsageEvent` metadata do not record prompt,
  observation, answer, or completion text.
- Do not add raw knowledge statements to span attributes. Use IDs and eval
  reports for debugging content-sensitive behavior.

## Gaps

Portability, packaging, and operations add daily per-scope budget counters over
the exact usage ledger, queue depth readiness/telemetry, and an allowlisted
redacted production JSON formatter. Remaining release-evidence work is:

- projection/cache metrics;
- release/nightly eval dashboards;
- full OpenTelemetry metrics export from app-level `telemetry_metrics`.
