<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# Configuration reference

Environment configuration is resolved at boot, never build time.

The annotated, complete example is
[`.env.example`](https://github.com/memhousehq/memhouse/blob/main/.env.example)
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
| `CARTULARY_PG0_DATABASE` | `memhouse` | Database name |
| `CARTULARY_PG0_USERNAME` / `_PASSWORD` | `postgres` | Local credentials |
| `ECTO_IPV6` | `false` | Connect over IPv6 |
| `CARTULARY_DATABASE_APP_ROLE` | `cartulary_app` | Restricted PostgreSQL role every connection switches to |
| `CARTULARY_ALLOW_UNRESTRICTED_DATABASE_ROLE` | `false` | Boot anyway if that role can't be provisioned or reached |

External mode needs PostgreSQL 18 with pgvector available.

!!! danger "The connecting role must be able to reach a restricted role, or boot fails"
    PostgreSQL skips RLS for superusers and `BYPASSRLS` roles. MemHouse serves
    traffic only through a role that is neither:

    - Give `DATABASE_URL`'s role `CREATEROLE`, and MemHouse provisions
      `CARTULARY_DATABASE_APP_ROLE` itself on every boot (idempotent) and
      switches every pooled connection to it.
    - Or point `DATABASE_URL` at a login already created with `NOSUPERUSER
      NOBYPASSRLS` — the stronger arrangement, since that connection then has
      no path back to elevated access at all.

    `CARTULARY_ALLOW_UNRESTRICTED_DATABASE_ROLE=true` bypasses this guard and
    logs an error at every start. It exists only to avoid stranding an upgrade,
    not for supported operation.

## Identity and secrets

| Variable | Meaning |
| --- | --- |
| `CARTULARY_FREE_ACCOUNT_KEY` | Key of the single community Account |
| `CARTULARY_FREE_ACCOUNT_NAME` | Its display name |
| `CARTULARY_AUTH_SIGNING_SECRET` | At least 64 random bytes. **Independent of `SECRET_KEY_BASE`** |
| `SECRET_KEY_BASE` | Phoenix session and token signing |
| `CARTULARY_BOOTSTRAP_PASSWORD` | Read only by the one-time bootstrap task |
| `CARTULARY_DATA_ROOT` | Private data root; defaults to `~/.memhouse` in a release |

!!! danger "Generate independent production secrets"
    Do not reuse `SECRET_KEY_BASE` as the auth signing secret. The bootstrap
    password need not remain in the environment after the first run.

## Updates

| Variable | Default | Meaning |
| --- | --- | --- |
| `CARTULARY_UPDATE_CHECK` | `true` | Check the official signed release feed at boot and periodically. |
| `CARTULARY_AUTO_UPDATE` | `off` | `off` or `minor`; the latter permits an eligible signed patch/minor update before standalone pg0 startup. |
| `CARTULARY_UPDATE_CHECK_INTERVAL_HOURS` | `24` | Availability-check interval while the application runs. |
| `CARTULARY_UPDATE_INSTALL_ROOT` | launcher parent | Root holding the `current` pointer and immutable `releases/` directories. |
| `CARTULARY_UPDATE_SOURCE` | official GitHub API | Release discovery endpoint. Artifact trust still comes from the signed manifest. |

Updates never self-replace Docker or external-PostgreSQL deployments. Those
surfaces report the available version and retain their normal deployment flow.

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
| `CARTULARY_MODEL_RECEIVE_TIMEOUT_MS` | `120000` | Maximum idle wait (ms) between response chunks |
| `CARTULARY_MODEL_REQUEST_TIMEOUT_MS` | `300000` | Total model-call ceiling (ms) shared by all three generation roles |
| `CARTULARY_MODEL_STREAM_POOL_SIZE` | `16` | Connections in each shared HTTP/1 shard |
| `CARTULARY_MODEL_STREAM_POOL_COUNT` | `1` | Shared HTTP/1 shard count; raise only for a measured shard bottleneck |
| `CARTULARY_MODEL_POOL_TIMEOUT_MS` | `120000` | Maximum wait (ms) to check out a model HTTP connection |
| `CARTULARY_INGEST_QUEUE_LIMIT` | `10` | Concurrent extraction jobs per node |

!!! warning "Reasoning models can blow the context window or time out without these"
    Reasoning models, including the default `openai/gpt-oss-120b`, can consume
    their context before producing output. `CARTULARY_MODEL_REASONING_EFFORT`
    bounds reasoning and `CARTULARY_MODEL_MAX_TOKENS` caps output. ReqLLM only
    extends timeouts automatically for recognized OpenAI reasoning families;
    `CARTULARY_MODEL_RECEIVE_TIMEOUT_MS` overrides its 30-second default for
    `openai/gpt-oss-120b` and other vendors. Raise these values only when the
    chosen model requires it.

`CARTULARY_MODEL_RECEIVE_TIMEOUT_MS` bounds the wait between response chunks.
`CARTULARY_MODEL_REQUEST_TIMEOUT_MS` bounds the complete response, even when a
provider continues sending chunks or keep-alives.

`CARTULARY_MODEL_STREAM_POOL_SIZE` must cover concurrent hosted model calls,
not just one role. Finch chooses a shard randomly when the count exceeds one,
so use `size` to add capacity and leave
`CARTULARY_MODEL_STREAM_POOL_COUNT=1` unless telemetry shows a single shard is
the bottleneck. `CARTULARY_MODEL_POOL_TIMEOUT_MS` is the maximum checkout wait
and defaults to the model receive timeout.

For 100 parallel ingestion flows on one node, set
`CARTULARY_INGEST_QUEUE_LIMIT=100` and
`CARTULARY_MODEL_STREAM_POOL_SIZE=128`, then validate the provider's
concurrency/rate limits and the database pool under representative load.

There are exactly four Account-level model roles: `embedder`,
`ingest_extractor`, `dream_reasoner`, and `dialectic_agent`. Only secret
*references* are persisted, never secret values.

When `CARTULARY_MODEL_PROVIDER=openrouter`, structured extraction and reasoning
use OpenRouter's strict JSON-schema response format. This is automatic; it
avoids models that intermittently ignore forced tool calls.

!!! warning "The local fallback is a test aid"
    Production defaults it off and never switches to it after a live provider
    error. A silent downgrade from a real model to a deterministic stand-in
    would corrupt memory quality invisibly.

## Embeddings

| Variable | Example | Meaning |
| --- | --- | --- |
| `CARTULARY_EMBEDDING_PROVIDER` | `ortex` | `ortex` (local ONNX) or `openai-compatible` |
| `CARTULARY_EMBEDDING_MODEL` | `Qwen/Qwen3-Embedding-0.6B` | Model identity |
| `CARTULARY_EMBEDDING_VERSION` | `onnx-1-qwen3-1024` | **The vector-space version** |
| `CARTULARY_EMBEDDING_DIMENSIONS` | `1024` | Vector width |
| `CARTULARY_ORTEX_MODEL_PATH` | absolute path | Operator-supplied `.onnx` file |
| `CARTULARY_ORTEX_TOKENIZER_PATH` | absolute path | Operator-supplied `tokenizer.json` |
| `CARTULARY_ORTEX_POOLING` | `last_token` | Pooling strategy |
| `CARTULARY_ORTEX_QUERY_INSTRUCTION` | Qwen3 retrieval instruction | Applied to query embeddings only |
| `CARTULARY_ORTEX_EXECUTION_PROVIDERS` | `cpu` | ONNX Runtime execution providers |
| `CARTULARY_EMBEDDING_BASE_URL` / `_API_KEY` | — | For an API embedder instead |

The Ortex embedder downloads nothing. Supply the official Qwen ONNX directory
from revision `b07450f1875a5c6cba3efbc775ceea725141bca2`. Keep `onnx/model.onnx`
beside `onnx/model.onnx_data`, and set the model path to `model.onnx` and the
tokenizer path to that revision's `onnx/tokenizer.json`. Download and verify
these files before starting MemHouse; runtime never contacts Hugging Face.

| File | SHA-256 at the pinned revision |
| --- | --- |
| `onnx/model.onnx` | `dd0996944757df30ba6cb252853e40c1f17270e5f3be5c58872e37c40bd7a27c` |
| `onnx/model.onnx_data` | `7c7569e58783ee0ad8c5fb797d7944aa4f5928af53fb4c1f626f71885af22969` |
| `onnx/tokenizer.json` | `def76fb086971c7867b829c23a26261e38d9d74e02139253b38aeb9df8b4b50a` |

Qwen3 requires an ONNX export with `input_ids` and `attention_mask`. It uses
mask-aware last-token pooling. Documents are embedded as supplied; retrieval
queries receive the configured instruction prefix. A switch from the former
384-dimensional identity requires a full, resumable re-embed. Until it
finishes, old vectors are intentionally absent from semantic retrieval.

### DiskANN

PostgreSQL must provide `vectorscale` 0.9.0. External mode fails at boot if the
extension is unavailable.

| Variable | Default | Meaning |
| --- | --- | --- |
| `CARTULARY_DISKANN_STORAGE_LAYOUT` | `memory_optimized` | SBQ layout; `plain` stores full vectors in the index |
| `CARTULARY_DISKANN_NUM_NEIGHBORS` | `50` | Graph neighbors per node at build time; `10` to `1000` |
| `CARTULARY_DISKANN_SEARCH_LIST_SIZE` | `100` | Candidate list used to build the graph; `10` to `1000` |
| `CARTULARY_DISKANN_MAX_ALPHA` | `1.2` | Build-time pruning factor; `1.0` to `5.0` |
| `CARTULARY_DISKANN_NUM_DIMENSIONS` | `0` | Indexed MRL prefix from `1` to `1024`; `0` uses all dimensions |
| `CARTULARY_DISKANN_QUERY_SEARCH_LIST_SIZE` | `100` | Approximate candidates visited per query; `1` to `10000` |
| `CARTULARY_DISKANN_QUERY_RESCORE` | `50` | Candidates rescored from full heap vectors; `0` to `1000` |

The five build settings require an index rebuild to take effect. Query settings
are transaction-local and apply to each semantic retrieval call.

!!! warning "Bump the embedding version on any artefact change"
    Provider, model, version, and dimensions together are the vector-space
    identity. A mismatch takes the explicit re-embed path; vectors are never
    reused or silently substituted across identities.

## Document storage

| Variable | Default | Meaning |
| --- | --- | --- |
| `CARTULARY_BLOB_ADAPTER` | `local` | `local` or `s3` |
| `CARTULARY_BLOB_ROOT` | env-dependent | Absolute local blob path (`/var/lib/memhouse/blobs` in production) |
| `CARTULARY_S3_BUCKET` | — | Bucket name |
| `CARTULARY_S3_PREFIX` | `memhouse` | Key prefix |
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

## Governance

| Variable | Default | Meaning |
| --- | --- | --- |
| `CARTULARY_GOVERNANCE_UNATTENDED` | `false` | Declares this whole deployment process has no human governance participant |

When true, personal knowledge above peer level receives an automatic subject
consent record. Normally only the subject's verified grant permits widening;
GateRule cannot waive it. Use this only for benchmarks, evaluations, or
synthetic deployments without real subjects. MemHouse logs it at boot and
reports it on `GET /api/ready`.

An individual Account can be marked the same way without touching the whole
deployment — see [Governance](../concepts/governance.md) for the
account-level `consent_mode` setting, which an account administrator
controls from within that Account rather than from the environment.

## Observability

| Variable | Default | Meaning |
| --- | --- | --- |
| `CARTULARY_OTEL_ENABLED` | `false` | Enable batch OTLP/HTTP trace export |
| `CARTULARY_ENVIRONMENT` | `development` | Environment label |
| `OTEL_SERVICE_NAME` | `memhouse-dev` | Service name in traces |
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
profile asks for. `CARTULARY_RETRIEVAL_RERANK_TIMEOUT_MS` defaults to `750`.
It is the most time reranking may use, but the request's remaining profile
deadline always wins when it is smaller. Raising it can improve thorough-search
ranking at the cost of tail latency; it cannot extend the 1500 ms hard ceiling.

Profile changes require product review; PostgreSQL location changes do not.
