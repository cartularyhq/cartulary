# Cartulary

Cartulary is a governed agent-memory system built on Elixir, Ash, Phoenix, and
Oban. Agents submit raw observations; a pipeline is the only writer of
knowledge; two governance gates decide what is retained, who it is attributed
to, and how widely it may be seen. Reads are scope-anchored, inherited
downward, cited, and able to abstain.

**Status: community beta, version `0.2.0`.** The memory engine, governance,
retrieval, document handling, packaging, and release machinery are implemented
and covered by tests. One capability is not: integration surfaces, gateway, and
generated SDKs. See [Not yet implemented](#not-yet-implemented).

The community release supervises a pinned pg0/PostgreSQL/pgvector distribution
for no-container installs, or runs against operator-run Postgres without any
behavioural difference. It supports local Ortex/ONNX embeddings and any
ReqLLM-supported or OpenAI-compatible generation endpoint.

## Contents

- [Capabilities](#capabilities)
- [Not yet implemented](#not-yet-implemented)
- [Quick start](#quick-start)
- [Configuration](#configuration)
- [Surfaces](#surfaces)
- [Operations](#operations)
- [Evaluation](#evaluation)
- [Checks](#checks)
- [Development observability](#development-observability)
- [Documentation map](#documentation-map)
- [License](#license)

## Capabilities

Ten Ash Domains and 38 Resources own the durable boundary. Every durable write
goes through an Ash action; Account isolation is enforced at the Phoenix edge,
in Ash policies, and in PostgreSQL row-level security.

**Ash domain backbone** — Resources are the durable type system and the policy
boundary. Message and document-version content is create-only, knowledge can
only be minted or merged by a pipeline actor, and lifecycle, audit, and usage
records are append-only. Generated migrations and resource snapshots stay in
sync with reviewed pgcrypto, pgvector, full-text-search, index, and RLS DDL.
→ `docs/architecture/ash-domain-backbone.md`

**Transactional writes, audit, and jobs** — Each ingest commits its raw
observation, a content-safe hash-chain audit event, a durable idempotency
record, and its AshOban job in one transaction. Eleven job lanes and four
Ash.Reactor flows cover extraction, dream-time reasoning, revalidation, expiry,
projection and entity refresh, connector sync, portability rebuild,
reconciliation, and governance continuations. Replays merge provenance instead
of duplicating knowledge, and a provider outage delays freshness rather than
losing observations.
→ `docs/architecture/transactional-writes-audit-jobs.md`

**Identity, tenancy, and RBAC** — AshAuthentication password/JWT identities for
humans and hashed per-Peer API keys for agents. Account is derived from the
authenticated identity, never from a header or request body. Role grants for
`account-admin`, `curator`, `member`, and `reader` inherit down the scope tree
and resolve deny-wins.
→ `docs/architecture/identity-tenancy-rbac.md`

**Gate A/B governance** — A versioned matrix over confidence, target level, and
sensitivity decides whether Gate A keeps, rejects, or defers an item and whether
Gate B may place it at the requested blast radius. The default is peer-level
provisional visibility plus human review; wider-scope proposals stay held and
out of retrieval, and upward personal attribution additionally requires
verified subject consent. Curator actions are reachable only by authenticated
human sessions — never by MCP or machine credentials. Peer self-view,
contest/redact, proportionate and strict erasure, revalidation, decay, and
escalation are all implemented.
→ `docs/architecture/gate-a-b-governance.md`

**Model layer and structured extraction** — One provider-neutral gateway over
ReqLLM with four Account-level roles: embedder, ingest extractor, dream
reasoner, and dialectic agent. Structured extraction uses Ash-derived schemas
with bounded validate-and-repair, resolves subject independently of source,
discounts hearsay, and records complete provenance. Embedding identity is
provider + model + version + dimensions; a mismatch takes the explicit re-embed
path and never silently substitutes vectors. One durable usage ledger meters
every call.
→ `docs/architecture/model-layer-structured-extraction.md`

**Documents, connectors, and sync** — Immutable hash-addressed document
versions over content-addressed local or S3-compatible blobs, MDEx and
ExtractousEx parsing, chunking and embedding for retrieval, and knowledge
extraction through the same pipeline and gates. Connector cursors advance only
after a page is durably handled; repeated hashes are no-ops; changed content
appends a version and supersedes stale derivations without rewriting history;
remote deletions become tombstones.
→ `docs/architecture/documents-connectors-sync.md`

**Retrieval, entity resolution, and context** — Independent Semantic, Lexical,
Temporal, SalienceRecency, and EntityMatch seed strategies plus hop-one
RelationExpand, combined by weighted reciprocal-rank fusion with optional
reranking. Named profiles are versioned, inherit nearest-wins, enforce a hard
deadline, and report contributed and dropped strategies. `search` defaults to
`:balanced`, `ask` to `:thorough`. Entity caches are internal and never
exposed. `get_context` assembles its budget from projections and stays
reasoning-free.
→ `docs/architecture/retrieval-entity-context.md`

**Skill readiness and procedural memory** — Human-authored, plain-versioned
skill requirement cards with a validated selector language, nearest-scope
requirement overrides, and a reasoning-free gap report. Required gaps block,
preferred gaps warn, and stale knowledge cannot satisfy a requirement.
→ `docs/architecture/skill-readiness-procedural-memory.md`

**Portability, packaging, and operations** — Cross-platform Mix releases with a
checksum-pinned pg0 binary, supervised lifecycle, first-run migration,
stale-lock recovery, and an external-Postgres escape hatch; a non-root
container over stock Postgres; verified whole-Account logical archives;
readiness endpoints; exact metering; and redacted structured logs.
→ `docs/architecture/portability-packaging-operations.md`

**Evaluation, CI, and release readiness** — Reproducible reports for Cartulary
product scenarios, LoCoMo, LongMemEval, ConvoMem, and BEAM with full
provenance, strategy ablations, and committed correctness and citation floors;
blocking external-Postgres and packaged-pg0 CI lanes; release and container
builds; and fail-closed release checks.
→ `docs/architecture/evaluation-ci-release-readiness.md`

The complete, evidence-backed inventory is `docs/implementation-status.md`.

## Not yet implemented

Cartulary does not ship these, and
`docs/eval/surface-contract-inventory.json` marks them `unavailable` so the
release check fails if they are advertised:

- generated AshJsonApi OpenAPI;
- complete generated TypeScript and Python clients — the modules under `sdk/`
  are transport-neutral readiness helpers, not SDKs;
- the OpenAI-compatible and Anthropic-compatible gateway proxy;
- the full grounded `ask` dialectic loop with in-loop citation verification;
- connector administration and Account archive administration UIs.

Upstream-scale benchmark scores and independent live-model judge evidence also
do not exist yet; the committed fixtures are deliberately smoke-scale.

All of it is tracked with acceptance criteria in
`docs/roadmap/beta-roadmap.md`.

## Quick start

### Downloaded release: one command

Unpack the release for your OS and architecture, then run:

```bash
bin/server
```

On Windows use `bin\server.bat`. The launcher creates a private data root,
generates the local signing secret, starts the packaged pg0 binary, migrates
the fresh database, and serves the API.

```bash
curl -fsS http://127.0.0.1:4000/api/ready
```

The release also accepts `CARTULARY_DATABASE_MODE=external` and `DATABASE_URL`
for operator-run Postgres. See `docs/operations/README.md` for install,
configuration, Compose, and upgrade procedures.

### Source development

Prerequisites are Elixir 1.17 or newer and PostgreSQL with pgvector on
`localhost:5432`. Source mode does not download infrastructure at boot.

```bash
cp .env.example .env
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

Start the server on `http://localhost:4000`:

```bash
mix phx.server
```

Sign in and use the returned token as `Authorization: Bearer <token>`:

```bash
curl -fsS -X POST http://127.0.0.1:4000/api/auth/password \
  -H 'content-type: application/json' \
  -d '{"email":"admin@example.test","password":"replace-with-a-long-password"}'
```

## Configuration

### Models

`OPENROUTER_API_KEY` is optional in development. If it is blank and
`CARTULARY_MODEL_LOCAL_FALLBACK=true`, an explicit deterministic local adapter
keeps tests and smoke runs offline. Production defaults that fallback off and
never switches to it after a provider failure.

```bash
CARTULARY_MODEL_PROVIDER=openrouter
OPENROUTER_API_KEY=...
CARTULARY_OPENAI_COMPAT_BASE_URL=https://openrouter.ai/api/v1
```

### Embeddings

The default embedding role is local Ortex/ONNX. The ONNX and tokenizer
artefacts are operator-supplied:

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
ONNX artefact, tokenizer, pooling, or dimensions change.

### Document blobs

Blob storage defaults to a content-addressed local directory; production
defaults to `/var/lib/cartulary/blobs`. An S3-compatible backend is a pure
runtime-configuration change:

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

## Surfaces

| Route | Purpose |
| --- | --- |
| `GET /api/health` | Liveness and contract identity |
| `GET /api/ready` | Component readiness: app, database, Oban, queues, model roles |
| `POST /api/v1/ingest` | Submit raw observations |
| `POST /api/v1/search` | Scoped retrieval, `:balanced` by default |
| `POST /api/v1/ask` | Cited answer over retrieved knowledge, `:thorough` by default |
| `POST /api/v1/context` | Reasoning-free projection-backed context |
| `POST /api/v1/readiness` | Skill-readiness gap report |
| `GET /api/v1/knowledge` | Governed knowledge query |
| `POST /api/auth/password` | Human sign-in |
| `/api/v1/self/*` | Peer self-view, contest, redact, erase — human credentials only |
| `/api/v1/operations/costs` | Self-host usage and cost, account-admin only |
| `/governance` | Curator LiveView and skill-card authoring, password sessions only |
| `/mcp` | AshAi MCP endpoint |

Every `/api/v1` route requires a password JWT or an agent API key. Account
headers and Account fields in request bodies do not select tenancy.

Machine credentials may submit raw observations, read governed memory, resolve
the calling peer's own frozen inline question, and lower that peer's ask
limits. They can never reach approve, edit, reject, merge, defer, promotion,
gate administration, or bulk curator actions.

Check readiness before a skill runs:

```bash
curl -fsS -X POST http://127.0.0.1:4000/api/v1/readiness \
  -H 'authorization: Bearer <token>' \
  -H 'content-type: application/json' \
  -d '{"skill":"write-copy","scope_path":"/marketing/social"}'
```

The report blocks on required gaps, warns on preferred gaps, and marks expired
or due-for-revalidation knowledge stale. Elicited answers go back through
ordinary `/api/v1/ingest`; callers rerun readiness after governance completes.

## Operations

```bash
curl -fsS http://127.0.0.1:4000/api/ready
curl -fsS http://127.0.0.1:4000/api/v1/operations/costs \
  -H 'authorization: Bearer <account-admin-token>'
```

Create, verify, and restore whole-Account logical archives with
`mix cartulary.portability.export` and `mix cartulary.portability.import`. The
exact release and source commands plus post-import checks are in
`docs/operations/portability.md`; physical database and blob recovery is in
`docs/operations/backup-restore.md`.

## Evaluation

Smoke run:

```bash
mix cartulary.eval.smoke --profile balanced --account eval-poc
```

Deterministic release matrix and readiness check:

```bash
mix cartulary.eval.release \
  --no-model \
  --assert-thresholds \
  --output /private/tmp/cartulary-release-eval.json

mix cartulary.release.check \
  --eval-report /private/tmp/cartulary-release-eval.json
```

Every published quality number must carry its full provenance: application
version, retrieval profile and exact profile version, all four model-role
versions, dataset id/SHA-256/split, deadline setting, date, judge identity,
strategy override, and run limits. The 2026-07-27 minimal reports under
`docs/eval/results/` are historical baseline evidence and are never relabelled
as current.

## Checks

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
  --output /private/tmp/cartulary-release-eval.json
mix cartulary.release.check \
  --eval-report /private/tmp/cartulary-release-eval.json
```

## Development observability

Cartulary can export development traces through OpenTelemetry. The local
collector stack in `dev/observability/` gives you Jaeger for traces, Prometheus
for collector metrics, collector debug logs, and an optional
Langfuse-forwarding config.

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
includes `x-trace-id`. Read `docs/observability/README.md` for the measurement
checklist, Langfuse setup, safe logging defaults, and eval evidence workflow.

Traces and logs record ids, counts, profile names, model names, strategy names,
timings, token counts, and error classes. They never record raw messages,
prompts, answers, API keys, restricted knowledge, or secrets.

## Documentation map

| Document | What it is for |
| --- | --- |
| `AGENTS.md` | The operating contract for agents and contributors. Read it first. |
| `docs/roadmap/beta-roadmap.md` | The only roadmap: what is left to build, with acceptance criteria. |
| `docs/implementation-status.md` | What runs today, its verification evidence, and its real limitations. |
| `docs/architecture/free-core-architecture.md` | Target decomposition, abstraction layers, durable-versus-derived rules, contract version identities. |
| `docs/architecture/` | One note per implemented capability. |
| `docs/adr/` | Architecture decision records. |
| `docs/operations/` | Install, upgrade, backup/restore, portability, versioning, release checklist. |
| `docs/eval/` | Evaluation harness, thresholds, surface inventory, historical results. |
| `docs/security/` | Security notes. |
| `specs/` | Blueprint: functional requirements, architecture and NFRs, product blueprint, evaluation framework. |

## Free core and enterprise

The free core is intended to include the full memory engine, single-node
self-hosting, local/offline model options, MCP, generated SDKs, gateway proxy,
basic RBAC, governed validation, document ingestion, retrieval, export/import,
and release-grade evaluation. Enterprise is the scale and compliance tier:
multiple Accounts, queue mode, SSO/SAML/SCIM, schema- or database-per-Account
isolation, granular RBAC, customer-managed keys, SIEM streaming, and advanced
compliance operations.

One codebase, two deployment modes, identical guarantees. Single-node and
queue-mode are the same Mix release with different adapters and runtime
configuration — never forks or simplified reimplementations.

## License

Cartulary is source-available fair-code, not OSI-open-source. Community and
core code is governed by `LICENSE.md`. Enterprise-marked code, when added, is
governed by `LICENSE_EE.md`.

Enterprise-only files must live under an `ee` directory or use `.ee.` in the
filename. Repository-owned source files carry SPDX headers identifying the
applicable license.
