<!-- SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0 -->

# Configuration reference

Everything is environment-driven and resolved at boot, never at build time.
There is no second project file and no build flag that forks behaviour.

The annotated, complete example is
[`.env.example`](https://github.com/cartularyhq/cartulary/blob/main/.env.example)
in the repository.

## Database

| Variable | Default | Meaning |
| --- | --- | --- |
| `CARTULARY_DATABASE_MODE` | `pg0` in a release | `pg0` (supervised) or `external` |
| `DATABASE_URL` | — | Required in external mode, e.g. `ecto://user:pass@host/db` |
| `POOL_SIZE` | `10` | Connection pool size |
| `CARTULARY_AUTO_MIGRATE` | `true` | Run migrations as a supervised startup step |
| `CARTULARY_PG0_BINARY` | packaged | Path to the pg0 binary |
| `CARTULARY_PG0_DATA_DIR` | under the data root | PostgreSQL data directory |
| `CARTULARY_PG0_PORT` | `5432` | Port the supervised server listens on |
| `CARTULARY_PG0_DATABASE` | `cartulary` | Database name |
| `CARTULARY_PG0_USERNAME` / `_PASSWORD` | `postgres` | Local credentials |
| `ECTO_IPV6` | `false` | Connect over IPv6 |

External mode needs PostgreSQL 18 with pgvector available.

## Identity and secrets

| Variable | Meaning |
| --- | --- |
| `CARTULARY_FREE_ACCOUNT_KEY` | Key of the single community Account |
| `CARTULARY_FREE_ACCOUNT_NAME` | Its display name |
| `CARTULARY_AUTH_SIGNING_SECRET` | At least 64 random bytes. **Independent of `SECRET_KEY_BASE`** |
| `SECRET_KEY_BASE` | Phoenix session and token signing |
| `CARTULARY_BOOTSTRAP_PASSWORD` | Read only by the one-time bootstrap task |
| `CARTULARY_DATA_ROOT` | Private data root; defaults to `~/.cartulary` in a release |

!!! danger "Generate independent production secrets"
    Do not reuse `SECRET_KEY_BASE` as the auth signing secret. The bootstrap
    password need not remain in the environment after the first run.

## Generation models

| Variable | Default | Meaning |
| --- | --- | --- |
| `CARTULARY_MODEL_PROVIDER` | `openrouter` | Provider identity |
| `CARTULARY_OPENAI_COMPAT_BASE_URL` | provider default | Any OpenAI-compatible endpoint, including self-hosted |
| `OPENROUTER_API_KEY` | — | Provider credential |
| `CARTULARY_MODEL_VERSION` | `unversioned` | Recorded with every result as provenance |
| `CARTULARY_MODEL_INGEST` | — | Model for the ingest-extractor role |
| `CARTULARY_MODEL_DREAM` | — | Model for the dream-reasoner role |
| `CARTULARY_MODEL_ASK` | — | Model for the dialectic-agent role |
| `CARTULARY_MODEL_LOCAL_FALLBACK` | `true` in dev, off in prod | Deterministic local adapter |
| `CARTULARY_MODEL_REASONING_EFFORT` | `low` | Reasoning-token budget shared by all three generation roles |
| `CARTULARY_MODEL_MAX_TOKENS` | `8192` | Output-token cap shared by all three generation roles |
| `CARTULARY_MODEL_RECEIVE_TIMEOUT_MS` | `120000` | Request timeout (ms) shared by all three generation roles |

!!! warning "Reasoning models can blow the context window or time out without these"
    A reasoning model (the default `openai/gpt-oss-120b` included) can spend an
    uncapped share of its context window on internal reasoning tokens before
    ever emitting output — regardless of how small the input is.
    `CARTULARY_MODEL_REASONING_EFFORT` bounds that spend directly; without it,
    a single small extraction can request as much output as the model's entire
    context length and fail outright. `CARTULARY_MODEL_MAX_TOKENS` is the hard
    backstop once reasoning is bounded. `CARTULARY_MODEL_RECEIVE_TIMEOUT_MS`
    matters separately: ReqLLM only extends its request timeout for model ids
    it recognizes as reasoning models (OpenAI's o-series, gpt-5, and codex
    families), so `openai/gpt-oss-120b` and reasoning models from other
    vendors get ReqLLM's plain 30-second default unless this is set. Raise
    these only if a chosen model genuinely needs a larger budget or more time
    to answer.

There are exactly four Account-level model roles: `embedder`,
`ingest_extractor`, `dream_reasoner`, and `dialectic_agent`. Only secret
*references* are persisted, never secret values.

!!! warning "The local fallback is a test aid"
    Production defaults it off and never switches to it after a live provider
    error. A silent downgrade from a real model to a deterministic stand-in
    would corrupt memory quality invisibly.

## Embeddings

| Variable | Example | Meaning |
| --- | --- | --- |
| `CARTULARY_EMBEDDING_PROVIDER` | `ortex` | `ortex` (local ONNX) or `openai-compatible` |
| `CARTULARY_EMBEDDING_MODEL` | `BAAI/bge-small-en-v1.5` | Model identity |
| `CARTULARY_EMBEDDING_VERSION` | `onnx-1` | **The vector-space version** |
| `CARTULARY_EMBEDDING_DIMENSIONS` | `384` | Vector width |
| `CARTULARY_ORTEX_MODEL_PATH` | absolute path | Operator-supplied `.onnx` file |
| `CARTULARY_ORTEX_TOKENIZER_PATH` | absolute path | Operator-supplied `tokenizer.json` |
| `CARTULARY_ORTEX_POOLING` | `cls` | Pooling strategy |
| `CARTULARY_ORTEX_EXECUTION_PROVIDERS` | `cpu` | ONNX Runtime execution providers |
| `CARTULARY_EMBEDDING_BASE_URL` / `_API_KEY` | — | For an API embedder instead |

The Ortex embedder downloads nothing: artefacts are deliberately
operator-supplied and offline.

!!! warning "Bump the embedding version on any artefact change"
    Provider, model, version, and dimensions together are the vector-space
    identity. A mismatch takes the explicit re-embed path; vectors are never
    reused or silently substituted across identities.

## Document storage

| Variable | Default | Meaning |
| --- | --- | --- |
| `CARTULARY_BLOB_ADAPTER` | `local` | `local` or `s3` |
| `CARTULARY_BLOB_ROOT` | env-dependent | Absolute local blob path (`/var/lib/cartulary/blobs` in production) |
| `CARTULARY_S3_BUCKET` | — | Bucket name |
| `CARTULARY_S3_PREFIX` | `cartulary` | Key prefix |
| `CARTULARY_S3_HOST` / `_SCHEME` / `_PORT` | — | For MinIO or another compatible endpoint |
| `AWS_REGION` and standard AWS variables | — | ExAws credentials |
| `CARTULARY_DOCUMENT_CHUNK_SIZE` | `1200` | Characters per chunk |
| `CARTULARY_DOCUMENT_CHUNK_OVERLAP` | `160` | Overlap between chunks |
| `CARTULARY_DOCUMENT_MAX_EXTRACT_LENGTH` | `500000` | Extraction cap in characters |

Blob adapter choice is a runtime infrastructure seam. It does not change
document semantics.

## Budgets and cost

| Variable | Meaning |
| --- | --- |
| `CARTULARY_BUDGET_LIMITS_JSON` | Daily token counters, e.g. `{"input_tokens":1000000,"output_tokens":250000,"embedding_tokens":2000000}` |
| `CARTULARY_MODEL_COSTS_JSON` | Operator rates in USD per million tokens, per role |

Dream-time is throttled first when a limit bites.

## Observability

| Variable | Default | Meaning |
| --- | --- | --- |
| `CARTULARY_OTEL_ENABLED` | `false` | Enable batch OTLP/HTTP trace export |
| `CARTULARY_ENVIRONMENT` | `development` | Environment label |
| `OTEL_SERVICE_NAME` | `cartulary-dev` | Service name in traces |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://localhost:14318` | Collector endpoint |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | `http_protobuf` | |
| `OTEL_TRACES_SAMPLER` / `_ARG` | always-on, `1.0` | Sampling |
| `CARTULARY_OTEL_*_SPANS_ENABLED` | see [Observability](../operations/observability.md) | Per-category span switches |
| `CARTULARY_OTEL_DB_STATEMENT_ENABLED` | `false` | SQL text in spans — off because statements can carry sensitive values |
| `CARTULARY_EXPERIMENT_NAME` / `_RUN_ID` | | Evaluation run labels |
| `CARTULARY_RETRIEVAL_VARIANT` | `poc-baseline` | Historical label kept for comparability with recorded runs |

## Web

| Variable | Default | Meaning |
| --- | --- | --- |
| `PORT` | `4000` | HTTP port |
| `PHX_HOST` | `localhost` | Public hostname |
| `PHX_SERVER` | `false` | Start the endpoint (set by the release launchers) |
| `DNS_CLUSTER_QUERY` | — | Clustering DNS query |

## Retrieval profiles

Profiles are configured in application config rather than the environment,
because they are behaviour rather than infrastructure. The shipped values:

| Profile | Strategies | Weights | Rerank | Deadline |
| --- | --- | --- | --- | --- |
| `fast` | semantic, salience-recency | 1.0, 0.8 | no | 100 ms |
| `balanced` | semantic, lexical, temporal, entity-match | 1.0, 1.0, 0.7, 0.9 | no | 300 ms |
| `thorough` | the above plus salience-recency and relation-expand | +0.8, 0.6 | yes | 1500 ms |

Fusion uses reciprocal rank with `k = 60`. `enabled_strategies` is a
deployment-level allowlist: a strategy absent from it never runs, whatever a
profile asks for.

Changing a profile changes product behaviour and needs review; pointing the
release at a different PostgreSQL does not.
