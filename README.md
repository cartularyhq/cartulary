# Cartulary

Cartulary is an Elixir/Ash/Phoenix/Oban memory system prototype for governed
agent memory on the BEAM. The current repository state combines the frozen
local POC contract with the implemented F1 Ash Domain Backbone and F2
Transactional Writes, Audit, And Jobs plus F3 Identity, Tenancy, And Basic
RBAC, F4 Real Gate A/B Governance, and F5 Model Layer And Structured
Extraction plus F6 Documents, Connectors, And Sync, F7 Retrieval, Entity, And
Context, F9 Skill Readiness And Procedural Memory, and F10 Portability,
Packaging, And Operations, plus F11 Evaluation, CI, And Release Readiness; it is
not yet a finished product architecture.

The community release supervises a pinned pg0/PostgreSQL/pgvector distribution
for no-container installs or uses operator-run Postgres without changing
behavior. It supports local Ortex/ONNX embeddings and a ReqLLM-supported or
OpenAI-compatible generation endpoint such as OpenRouter with
`openai/gpt-oss-120b`.

The target free self-host core is documented in
`docs/roadmap/free-core-roadmap.md`. That plan starts from the POC handoff,
keeps the ARCH directive of one codebase and identical guarantees, and lays out
the Ash/Phoenix/Oban architecture, abstraction layers, decomposition, migration
phases, and feature coverage needed for a complete single-Account community
solution.

Roadmap phases F0 through F7 and F9 through F11 are complete; F8 remains an explicit
surface/SDK prerequisite and is not implied complete by the F9 helper modules.
F0 response shapes, persistence,
scope inheritance, pipeline-only knowledge writes, and tiny eval fixtures
remain regression floors. F4 intentionally versions lifecycle behavior to
`f4-1`: new proposals are provisionally peer-visible or held for governance
instead of being auto-activated. F5 advances extraction to `f5-1` with four
pinned model roles, Ash-backed structured validation and repair, complete model
provenance, and exact usage events. F6 adds immutable document versions,
content-addressed Local/S3 blobs, native parsing, chunks and embeddings,
incremental connector sync, and document portability. Ten Ash Domains and 38
Resources own the durable boundary.

## What Runs Today

- Phoenix API skeleton with health, ingest, search, ask, context, and knowledge
  endpoints, plus the F9 readiness pre-flight.
- Postgres schema for accounts, peers, scopes, sessions, raw messages,
  documents, knowledge/provenance/lifecycle, governance/config, projections,
  entities, skill cards, and usage events.
- Ash actions and policies for Account isolation, scope reads, pipeline-only
  knowledge writes, governance separation, immutable content, and append-only
  ledgers.
- Versioned Gate A/B matrix evaluation with provisional peer visibility, held
  wider-scope proposals, corroboration thresholds, subject consent, and
  immutable decision history.
- Password-session-only LiveView governance queue with approve,
  edit-as-replacement, reject, merge, defer, bulk, provenance, and conflict
  handling.
- Peer self-view, contest/redact, proportionate/strict erasure, projection/entity
  recomputation, revalidation, expiry, confidence decay, escalation, and stale
  auto-rejection.
- AshAi MCP tools for raw ingest and governed reads, including deadline-bounded
  inline self-validation with transcript assurance and peer-lowerable ask
  limits, plus inherited `check_readiness`. Curator and skill-card authoring
  actions are not exposed to MCP or machine credentials.
- Plain-versioned `f9-1` skill requirement cards with validated metadata
  selectors, requirement-level nearest-scope overrides, lifecycle-aware gap
  reports, required blockers, preferred warnings, and provider-neutral
  TypeScript/Python elicitation helpers.
- AshAuthentication password/JWT identities for humans and hashed API-key
  identities for agents, linked to Peers with assurance levels.
- One authenticated community Account, enforced by a database free-edition
  slot, with inherited allow/deny role grants for account-admin, curator,
  member, and reader.
- Transactional message/document ingestion that commits a content-safe
  hash-chain audit event, durable idempotency record, and AshOban job together.
- Immutable document-version history with content-addressed Local or
  S3-compatible blob storage, MDEx/ExtractousEx parsing, TextChunker chunking,
  and bitcrowd/rag embedding integration.
- Incremental connector scheduling with durable cursors, hash-based no-op
  detection, tombstones, and provenance-preserving knowledge supersession.
- Checksum-verified document export/import and erasure that rebuild derived
  chunks instead of treating caches as durable state.
- Versioned whole-Account archives with manifest/resource/blob checksums,
  complete audit-chain verification, credential/vector/cache exclusions, and
  replay-keyed rebuild work on fresh import.
- Cross-platform Mix releases with checksum-pinned pg0, first-run migrations,
  supervised shutdown, stale-lock recovery, explicit port conflicts, and an
  external-Postgres escape hatch.
- A non-root container image and Compose stack using stock Postgres, with an
  optional OpenTelemetry Collector, Jaeger, and Prometheus profile.
- Versioned readiness for the app, database, Oban, queues, and model roles,
  redacted JSON production logs, exact request/token/storage metering,
  dream-time budget admission, and self-host cost visibility.
- `f11-1` reproducible evaluation reports for Cartulary, LoCoMo, LongMemEval,
  ConvoMem, and BEAM with dataset hashes/splits, exact profile and model-role
  versions, deadline identity, RAG-triad/token/latency measures, category and
  degradation evidence, and strategy ablations.
- Blocking external-Postgres and packaged-pg0 CI lanes, Dialyzer/security gates,
  Mix-release and container builds, nightly evaluation, semantic version/tag
  validation, and fail-closed release checks.
- Eleven AshOban lanes for extraction, dream-time, revalidation, expiry,
  projection/entity refresh, connector sync, portability rebuild,
  reconciliation, and governance continuations.
- Ash.Reactor flows for ingest extraction, dream-time reasoning, validation
  continuation, and transcript answer correlation.
- Per-Account SHA-256 audit chains and an Account-scoped reconciler for raw
  messages, document versions, and due connectors not yet processed.
- PostgreSQL RLS on every Account-scoped table, plus generated AshPostgres
  snapshots/migrations, foreign keys, FTS, and supporting indexes.
- pgcrypto, Postgres FTS, Oban tables, and pgvector extension migration.
- A single POC memory service that writes raw messages, extracts knowledge
  through the pipeline, retrieves candidates, and returns grounded answers with
  citations.
- Provider-neutral model gateway over ReqLLM with pinned embedder, ingest
  extractor, dream reasoner, and dialectic roles.
- Ash-backed structured extraction/reasoning schemas with bounded repair,
  subject/source separation, hearsay discounting, temporal proposals, model
  provenance, and one durable usage ledger.
- Local Ortex/ONNX `AshAi.EmbeddingModel`, an API embedding adapter, and an
  explicit versioned re-embed guard against incompatible vectors.
- Built-in smoke harness for tiny LoCoMo, LongMemEval, and BEAM-style memory
  paths:

```bash
mix cartulary.eval.smoke --profile balanced --account eval-poc
```

## Local Setup

### Downloaded release: one command

Unpack the release for the current OS and architecture, then run:

```bash
bin/server
```

On Windows use `bin\server.bat`. The launcher creates a private data root,
generates the local signing secret, starts the packaged pg0 binary, migrates the
fresh database, and serves the API. The readiness endpoint is:

```bash
curl -fsS http://127.0.0.1:4000/api/ready
```

The release also accepts `CARTULARY_DATABASE_MODE=external` and `DATABASE_URL`
for operator-run Postgres. See `docs/operations/README.md` for install,
configuration, Compose, and upgrade procedures.

### Source development

Prerequisites are Elixir 1.17 or newer and PostgreSQL with pgvector on
`localhost:5432`. The repository's normal local database is a pg0-backed
Postgres instance, but source mode does not download infrastructure at boot.

Create your local environment file:

```bash
cp .env.example .env
```

`OPENROUTER_API_KEY` is optional in development. If it is blank and
`CARTULARY_MODEL_LOCAL_FALLBACK=true`, the explicit deterministic local adapter
keeps tests and smoke runs offline. Production defaults this fallback off and
never switches to it after a provider failure. To use OpenRouter or another
ReqLLM/OpenAI-compatible endpoint, set:

```bash
CARTULARY_MODEL_PROVIDER=openrouter
OPENROUTER_API_KEY=...
CARTULARY_OPENAI_COMPAT_BASE_URL=https://openrouter.ai/api/v1
```

The default embedding role is local Ortex/ONNX. Point it at pinned local
artifacts:

```bash
CARTULARY_EMBEDDING_PROVIDER=ortex
CARTULARY_EMBEDDING_MODEL=BAAI/bge-small-en-v1.5
CARTULARY_EMBEDDING_VERSION=onnx-1
CARTULARY_EMBEDDING_DIMENSIONS=384
CARTULARY_ORTEX_MODEL_PATH=/absolute/path/to/model.onnx
CARTULARY_ORTEX_TOKENIZER_PATH=/absolute/path/to/tokenizer.json
CARTULARY_ORTEX_POOLING=cls
```

Treat the embedding version as the vector-space version: bump it whenever the
ONNX artifact, tokenizer, pooling, or dimensions change.

Document blobs default to a content-addressed local directory. Production
defaults to `/var/lib/cartulary/blobs`; an S3-compatible backend is selected
entirely through runtime configuration:

```bash
CARTULARY_BLOB_ADAPTER=local
CARTULARY_BLOB_ROOT=/absolute/path/to/cartulary-blobs
CARTULARY_DOCUMENT_CHUNK_SIZE=1200
CARTULARY_DOCUMENT_CHUNK_OVERLAP=160
CARTULARY_DOCUMENT_MAX_EXTRACT_LENGTH=500000

# Or use ExAws with the normal AWS/S3-compatible environment:
CARTULARY_BLOB_ADAPTER=s3
CARTULARY_S3_BUCKET=cartulary
CARTULARY_S3_PREFIX=cartulary
# Optional for MinIO or another compatible endpoint:
CARTULARY_S3_HOST=localhost
CARTULARY_S3_SCHEME=http://
CARTULARY_S3_PORT=9000
```

Install dependencies and migrate:

```bash
mix deps.get
mix ecto.migrate
```

Bootstrap the community Account and first administrator:

```bash
CARTULARY_BOOTSTRAP_PASSWORD='replace-with-a-long-password' \
  mix cartulary.identity.bootstrap \
    --email admin@example.test \
    --name 'Local Admin'
```

Start the Phoenix server:

```bash
mix phx.server
```

The API listens at:

```bash
http://localhost:4000
```

Health check:

```bash
curl -fsS http://127.0.0.1:4000/api/health
```

Operator readiness and exact self-host usage/cost visibility:

```bash
curl -fsS http://127.0.0.1:4000/api/ready
curl -fsS http://127.0.0.1:4000/api/v1/operations/costs \
  -H 'authorization: Bearer <account-admin-token>'
```

Create, verify, and restore whole-Account logical archives with
`mix cartulary.portability.export` and
`mix cartulary.portability.import`. The exact release/source commands and
post-import checks are in `docs/operations/portability.md`; physical database
and blob recovery is in `docs/operations/backup-restore.md`.

Sign in and use the returned token as `Authorization: Bearer <token>`:

```bash
curl -fsS -X POST http://127.0.0.1:4000/api/auth/password \
  -H 'content-type: application/json' \
  -d '{"email":"admin@example.test","password":"replace-with-a-long-password"}'
```

All `/api/v1` routes require a password JWT or agent API key. Account headers
and Account fields in request bodies do not select tenancy.

Human account administrators and curators can sign in to the governance queue
at `http://localhost:4000/governance/sign-in`. Authenticated human peers can
inspect, contest, redact, or erase their own subject knowledge through the
`/api/v1/self/*` routes. Machine credentials cannot use those human-governance
routes. The governance screen also authors and reviews skill requirement cards.
The MCP endpoint is `/mcp`.

Check readiness before a skill runs:

```bash
curl -fsS -X POST http://127.0.0.1:4000/api/v1/readiness \
  -H 'authorization: Bearer <token>' \
  -H 'content-type: application/json' \
  -d '{"skill":"write-copy","scope_path":"/marketing/social"}'
```

The `f9-1` report blocks on required gaps, warns on preferred gaps, and marks
expired or due-for-revalidation knowledge stale. Elicited answers go through
ordinary `/api/v1/ingest`; callers rerun readiness after governance completes.

Run the local smoke eval:

```bash
mix cartulary.eval.smoke --profile balanced --account eval-poc
```

Run the deterministic F11 release matrix:

```bash
mix cartulary.eval.release \
  --no-model \
  --assert-thresholds \
  --output /private/tmp/cartulary-f11-release.json

mix cartulary.release.check \
  --eval-report /private/tmp/cartulary-f11-release.json
```

Run the test gate:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test
```

## POC Log

The implementation log, known shortcuts, verification evidence, and refactor
plan are maintained in:

- `docs/poc-local-proof.md`
- `docs/roadmap/free-core-roadmap.md`

Read both documents before treating any POC code as an architectural precedent
or before migrating POC behavior into the free-core architecture.

## F0 Contract And F7 Retrieval Version

F0 freezes behavior, not the POC's internal design. `Cartulary.Memory` is now a
compatibility facade over authoritative Ash actions. F2 owns transactional
audit/AshOban behavior; F7 owns profile-based retrieval and projection-backed
context. Database-native FTS, pgvector, and hop-one reads are confined to the
reviewed read-only retrieval data layer.

The F0 contract evidence covers:

- its original six HTTP endpoints: health, ingest, search, ask, context, and
  knowledge; F9 adds readiness as a separately versioned surface;
- raw message persistence, pipeline-created knowledge, lifecycle insertion, and
  downward-only scope inheritance;
- identity-derived HTTP Account selection, including regressions proving the
  deprecated header and body data cannot override it;
- the absence of a direct agent knowledge-write route; and
- stable source hashes plus normalized IDs for the tiny Cartulary, LoCoMo,
  LongMemEval, and BEAM fixtures.

F4 intentionally changes the lifecycle portion of that contract from the POC
`active` shortcut to `proposed → provisional` by default, with scope-level
promotion held until Gate B approval and any required consent. Health reports
`f5-1`. F5 changes extractor/pipeline identity from `poc-0` to `f5-1` while
preserving the F0 payload shapes. F7 intentionally advances search, ask, and
context profile identity from `poc-0` to `f7-1`; the F0 HTTP evidence records
that explicit contract transition.

Run the focused F0 contract:

```bash
mix test \
  test/cartulary/poc_contract_test.exs \
  test/cartulary_web/controllers/memory_controller_test.exs \
  test/cartulary/eval/fixture_contract_test.exs
```

The authoritative checklist and evidence paths are in
`docs/roadmap/free-core-roadmap.md`.

## F1 Ash Domain Backbone

F1 registers Account, topology, observation, knowledge, governance, model,
retrieval, skill, and operations domains. Message/document-version content is
create-only; knowledge statements can only be minted or merged by a pipeline
actor; lifecycle/audit/usage records are append-only.

Account isolation is enforced by Ash actor/tenant policy and PostgreSQL RLS.
F3 now supplies the authenticated actor at the Phoenix edge; legacy account-key
helpers are internal eval/migration compatibility adapters only.

Read the implementation boundary, resource map, evidence, and transition
tickets in `docs/architecture/f1-ash-domain-backbone.md`.

## F2 Transactional Writes, Audit, And Jobs

Every message ingest now commits its raw observation, immutable content-safe
audit event, deterministic `PipelineRun`, and AshOban job in one Postgres
transaction. A failure after enqueue rolls the whole operation back. The raw
write and job commit before any model call, so provider outages delay
freshness rather than losing observations.

Pipeline jobs use deterministic keys and Account-local advisory locks where a
knowledge merge must serialize. Replays merge attribution/provenance into the
existing item and do not duplicate knowledge or its creation lifecycle. The
same job and queue implementation runs against pg0 and operator-run Postgres.

Read the full transaction map, job/Reactor lanes, audit-chain format,
later-phase boundaries, and evidence in
`docs/architecture/f2-transactional-writes-audit-jobs.md`.

## F3 Identity, Tenancy, And Basic RBAC

Humans authenticate locally through the AshAuthentication password strategy
and receive tenant-bound JWTs. Agents use per-Peer AshAuthentication API keys;
only hashes are stored. External identity links record assurance, and every
request actor receives effective scope roles from propagating grants with
deny-wins subtree carve-outs.

The community release provisions one authenticated Account. A later
enterprise migration can replace that provisioning constraint without changing
the identity-to-Ash-tenant/RLS contract.

Read the identity flows, API-key RLS bootstrap, role algorithm, contract
transition, and evidence in
`docs/architecture/f3-identity-tenancy-basic-rbac.md`.

## F4 Real Gate A/B Governance

Every extracted knowledge item now enters the real governance lifecycle. A
versioned Account/scope matrix decides whether Gate A keeps, rejects, or defers
it and whether Gate B may place it at the requested blast radius. The
conservative default is peer-level provisional visibility plus human review;
pending scope/account knowledge remains held and cannot enter retrieval.
Personal upward promotion additionally requires verified subject consent.

Curator actions are available only to authenticated password identities through
the LiveView queue and human-only Ash policies. Peer confirmation, consent, and
revalidation can ride on MCP reads, but only for the calling peer and only when
the frozen statement is evidenced in the ingested transcript. Governance
history and the audit chain store content-safe identifiers and hashes rather
than copying knowledge into telemetry or job arguments.

Read the resource map, state flow, surfaces, aging/erasure behavior, contract
transition, and evidence in
`docs/architecture/f4-real-gate-a-b-governance.md`.

## F5 Model Layer And Structured Extraction

Every model capability now enters through one injectable provider behavior.
Account-level role records or runtime config pin the provider, model, model
version, prompt version, pipeline version, options, and embedding dimensions.
ReqLLM handles generation, embeddings, and reranking across supported
providers; the default offline embedder uses Ortex/ONNX through
`AshAi.EmbeddingModel`.

Extraction and dream reasoning share a structured generator with an
Ash-derived schema and at most two validate-and-repair attempts. Extraction
resolves subject independently of source, discounts hearsay, proposes
confidence/sensitivity/target/time fields and an update operation, persists
full provenance, then enters the unchanged F4 Gate A/B lifecycle. Every call
emits one content-safe, Account/scope-attributed usage event. Provider failure
keeps raw observations and retryable jobs durable. F7 keeps normal
`get_context` assembly reasoning-free and permits only its bounded `:fast`
retrieval fallback after a projection miss.

Read the model boundary, schemas, embedding identity rule, outage behavior,
contract transition, and evidence in
`docs/architecture/f5-model-layer-structured-extraction.md`.

## F6 Documents, Connectors, And Sync

Documents now enter through the same governed observation pipeline as
messages. Each logical document keeps immutable hash-addressed versions and
blob references; MDEx handles Markdown, ExtractousEx handles supported binary
formats, and the parsed text is chunked and embedded with pinned F5 identity
before structured extraction and F4 governance.

Connector adapters pull raw pages behind one behavior. Their schedules and
cursors are durable, a repeated hash is a no-op, changed content appends a
version and supersedes stale derivations without rewriting history, and remote
deletions become tombstones. The document portability component exports
checksum-verified durable blobs and metadata while excluding rebuildable
chunks and vectors.

Read the storage boundary, transaction flow, sync semantics, erasure and
portability behavior, version posture, and evidence in
`docs/architecture/f6-documents-connectors-sync.md`.

## F7 Retrieval, Entity Resolution, And Context

Retrieval now runs independent Semantic, Lexical, Temporal,
SalienceRecency, and EntityMatch seed strategies, followed by hop-one
RelationExpand over knowledge, permission-filtered scope, and shared-entity
edges. Weighted reciprocal-rank fusion combines strategy-local ranks;
`:thorough` optionally reranks the fused head. Named profiles are versioned,
inherit nearest-wins from scope configuration, honor deployment strategy
constraints, enforce a hard deadline, and report contributed and dropped
strategies.

Knowledge and document chunks use PostgreSQL `vector` values with pinned
provider/model/version/dimension identity, HNSW cosine indexes, and PG-FTS GIN
indexes. Replay-safe projection jobs backfill knowledge vectors, run the
dream-time exact/embedding/reasoner entity cascade, and update bounded-delta
scope cards, peer profiles, and session summaries. Entity rows and aliases
remain internal derived caches and are never exposed through public routes.

`get_context` reads clean projections through an ETS cache with PubSub
invalidation, reserves its budget for summary/profile/cards before knowledge,
and stays reasoning-free. Its only live retrieval work is the allowed `:fast`
fallback after a cache miss. `search` defaults to `:balanced`; `ask` defaults to
`:thorough`.

Read the strategy contracts, security filtering, vector/index shape, entity
privacy, projection lifecycle, runtime controls, version transition, and
evidence in `docs/architecture/f7-retrieval-entity-context.md`.

## F9 Skill Readiness And Procedural Memory

Skill requirement cards are authored, plain-versioned contracts rather than
knowledge assertions. The `f9-1` selector language matches governed knowledge
metadata, subject, provenance source, confidence/corroboration, and freshness.
Requirement keys inherit down the scope tree with nearest-scope overrides or
explicit disablement.

`POST /api/v1/readiness`, the AshAi MCP `check_readiness` tool, and the internal
Skills action all return the same reasoning-free gap report. Required gaps
block, preferred gaps warn, a missing card blocks, and active-looking knowledge
whose expiry or revalidation deadline is due is already stale even before the
lifecycle sweeper runs. `ask-peer`/`either` gaps include an elicitation plan;
answers still enter as raw observations and must pass ordinary governance.

The governance LiveView publishes and reviews card versions. Transport-neutral
TypeScript and Python helpers under `sdk/` enforce server blockers and prepare
elicitation prompts; generation and packaging of the complete clients remains
F8 scope.

Read the selector schema, inheritance algorithm, lifecycle/source semantics,
surface contract, content-safe telemetry posture, migration, and evidence in
`docs/architecture/f9-skill-readiness-procedural-memory.md`.

## F10 Portability, Packaging, And Operations

F10 keeps one release and one durable Ash boundary across embedded pg0 and
external Postgres. Platform packages checksum and stage pg0 v0.14.2; the
release supervises its lifecycle and migrations. The container path uses stock
Postgres and the same Repo, migrations, Oban jobs, policies, and APIs.

Whole-Account archives stream 33 durable Resource types plus original document
blobs, verify every checksum and the full audit graph before import, exclude
credentials/secrets and rebuildable caches, restore through private Ash
actions, and enqueue deterministic scope/document rebuilds. Readiness, exact
metering, budget counters, structured redaction, queue metrics, and self-host
cost inspection complete the operator boundary.

Read the design and evidence in
`docs/architecture/f10-portability-packaging-operations.md` and begin operating
the community release at `docs/operations/README.md`.

## F11 Evaluation, CI, And Release Readiness

F11 separates blocking deterministic guardrails from frontier-tracked quality,
latency, and token efficiency. Every current claim report identifies the
Cartulary semantic version, date, dataset id/SHA-256/split, profile and exact
version, deadline setting, strategy override, all four model-role versions,
judge method, and run limits. The historical `poc-0` minimal reports remain the
Stage 0 baseline rather than being relabeled as `f7-1`.

CI runs the complete suite against external Postgres and a checksum-built
packaged pg0 instance, then builds the same Mix release and production
container. Nightly and semantic-tag workflows run the release matrix; the tag
workflow fails unless version, changelog, tag, deterministic thresholds, and
eval evidence agree.

Cartulary uses Semantic Versioning and a Keep-a-Changelog-style `CHANGELOG.md`.
Read the implementation and evidence in
`docs/architecture/f11-evaluation-ci-release-readiness.md`, the evaluation
framework in `specs/memory-system-evaluation-framework.md`, and the operator
procedure in `docs/operations/release-checklist.md`.

## Free Core Direction

The free core is intended to include the full memory engine, single-node
self-hosting, local/offline model options, MCP, generated SDKs, gateway proxy,
basic RBAC, governed validation, document ingestion, retrieval, export/import,
and release-grade evals. Enterprise remains the scale and compliance tier:
multiple Accounts, queue mode, SSO/SAML/SCIM, schema/db-per-Account isolation,
CMK, SIEM streaming, and advanced compliance operations.

## License

Cartulary is source-available fair-code, not OSI-open-source. Community/core
code is governed by `LICENSE.md`. Enterprise-marked code, when added, is governed
by `LICENSE_EE.md`.

The intended boundary follows the product blueprint:

- Free self-host core: full engine, MCP/SDK surfaces, single-node mode, basic
  RBAC, local/offline model options, and one Account.
- Enterprise license: multiple Accounts, queue mode, SSO/SAML/SCIM, stronger
  account isolation options, granular RBAC, audit export, CMK, and compliance
  features.

Enterprise-only files must be placed under an `ee` directory or use `.ee.` in
the filename. Repository-owned source files use SPDX headers to identify the
applicable license.

## Known POC Cuts

The important cuts are intentional and temporary:

- F2 provides the durable lanes for dream-time, lifecycle, connector,
  portability, and projection work. F4 through F6 now supply governance,
  structured reasoning, document connectors, and the document portability
  component; F7 supplies retrieval/entity/projection execution, and F10
  supplies Account-wide archives and operational packaging. Full
  reasoning-result application remains later work.
- The F11 eval/report/CI framework is release-grade, but committed benchmark
  fixtures are deliberately smoke-scale. Upstream-scale scores and independent
  live-model judge evidence must be produced with protected credentials and
  immutable upstream datasets before making comparative quality claims.
- F5 provides a cassette-tested provider seam, but production model artifacts,
  broader provider certification, and release eval thresholds remain operator
  and later-roadmap work.
- F9 ships the readiness helpers consumed by future generated SDKs. F8 still
  owns the full generated clients, OpenAPI packaging, and gateway surface.

## Checks

For code changes, run:

```bash
mix deps.get
mix ash.codegen --check
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix credo --strict
mix dialyzer
mix sobelow --config
mix cartulary.eval.release --no-model --assert-thresholds \
  --output /private/tmp/cartulary-f11-release.json
mix cartulary.release.check \
  --eval-report /private/tmp/cartulary-f11-release.json
```

## Development Observability

Cartulary can export development traces through OpenTelemetry. The local
collector stack is in `dev/observability/` and gives you Jaeger for traces,
Prometheus for collector metrics, collector debug logs, and an optional
Langfuse-forwarding config for LLM experiment analysis.

Start the stack:

```bash
docker compose -f dev/observability/docker-compose.yml up
```

Enable app export in `.env`:

```bash
CARTULARY_OTEL_ENABLED=true
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:14318
```

Watch traces at `http://localhost:16686` with service `cartulary-dev`. The
collector's host OTLP port defaults to `14318` to avoid common local `4318`
conflicts; override `CARTULARY_OTEL_HTTP_PORT` if needed. Each HTTP response
includes `x-trace-id`, which you can paste into Jaeger. Read
`docs/observability/README.md` for the measurement checklist, Langfuse setup,
safe logging defaults, and eval evidence workflow.
