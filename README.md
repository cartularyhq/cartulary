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

📖 **User documentation: <https://cartularyhq.github.io/cartulary/>** — install,
usage, operations, and how the system works, with diagrams. This README is the
repository orientation; the site is the manual.

## Contents

- [Core concepts](#core-concepts)
- [How a request flows](#how-a-request-flows)
- [Capabilities](#capabilities)
- [Not yet implemented](#not-yet-implemented)
- [Quick start](#quick-start)
- [Configuration](#configuration)
- [Surfaces](#surfaces)
- [Operations](#operations)
- [Evaluation](#evaluation)
- [Checks](#checks)
- [Development observability](#development-observability)
- [Repository layout](#repository-layout)
- [Reading the code](#reading-the-code)
- [Documentation map](#documentation-map)
- [License](#license)

## Core concepts

Nine terms carry most of the design. Everything else in this README assumes
them.

**Account** — the isolation boundary. Every durable row belongs to exactly one
Account. The Account is derived from the authenticated identity, never from a
header, query parameter, or request body, and it is enforced three times over:
at the Phoenix edge, in Ash policies, and in PostgreSQL row-level security. The
community build serves a single Account; multi-Account operation is an
enterprise concern.

**Scope** — a path in a containment tree, such as `/marketing/social`. Anything
attached to a scope is visible to everything beneath it. Inheritance is
downward and nearest-wins: a value set on a child overrides the same value
inherited from an ancestor.

**Peer** — one participant: a human, or an agent holding an API key. Peers are
the narrowest audience a piece of knowledge can have.

**Knowledge** — the only durable atom of memory: one natural-language statement
with its own confidence, sensitivity, lifecycle state, subject, and
provenance. Its text is immutable once written. Profiles, scope cards, and
session summaries are not separate stores — they are projections recomputed
from knowledge, and can be thrown away and rebuilt.

**Raw observation** — what agents actually submit: a message, or a document
version. Agents never write knowledge. The extraction pipeline is the only
writer of knowledge, which is what keeps a compromised or confused agent from
editing memory directly.

**Gate A and Gate B** — the two checks between an observation and durable,
visible memory. Gate A decides whether a candidate statement is kept, rejected,
or deferred for review. Gate B decides how widely it may be seen. Context flows
downward freely; new knowledge only flows upward through Gate B.

**Blast radius** — how far a statement can be seen: one peer, a scope, or the
whole Account. The wider the radius, the higher the bar. Peer-level provisional
visibility is the default; scope- and account-level proposals stay `held`, are
absent from retrieval, and need human curator approval. Knowledge attributed to
a person additionally needs that person's verified consent, which no curator
can substitute for.

**Lifecycle state** — every statement is created `proposed` and then moves to
`provisional`, `active`, or `held`; later it may become `needs_revalidation`,
`contested`, `superseded`, `expired`, `stale`, `rejected`, `redacted`, or
`retracted`. Retrieval filters on this, so the state alone decides whether
anyone ever sees a statement.

**Projection, index, and cache** — derived, rebuildable data: context
projections, entity rows, full-text and vector indexes, ETS counters. Raw
messages, governed knowledge, and the audit log are the system of record.
Anything derived may be deleted and recomputed; anything durable may not.

Two independence rules cut across all of it. Belief-time (when we learned it),
valid-time (when it was true), and salience are three different clocks.
Confidence, sensitivity, and the subject of a statement are three different
axes — in particular, who a statement is *about* is not who it came *from*.

## How a request flows

An ingest is the shortest path through the whole system:

1. `POST /api/v1/ingest` hits a plug that resolves the API key or password JWT
   into an actor, and derives the Account from it.
2. `Cartulary.Memory` opens one transaction that writes the raw message, a
   content-safe hash-chain audit entry, a durable idempotency record, and the
   extraction job. Either all four commit or none do, so a crash can never
   leave an audit gap or an orphaned job.
3. The pipeline extracts candidate statements through
   `Cartulary.Model.Gateway`, using a schema derived from the Ash resources so
   malformed provider output is repaired or rejected rather than stored.
4. `Cartulary.Governance.Engine` runs Gate A and Gate B over each candidate and
   assigns a lifecycle state and a blast radius.
5. Surviving knowledge is embedded and indexed. Projections are marked dirty
   and recomputed in the background.
6. `POST /api/v1/search` and `/api/v1/ask` read it back through
   `Cartulary.Retrieval.Strategy`, which applies Account, scope authorization,
   and lifecycle filters *before* candidates leave retrieval internals, then
   fuses several independent strategies into one ranked list.

A provider outage stops step 3, not step 2: the observation is durable and the
job retries.

## Capabilities

Ten Ash Domains and 38 Resources own the durable boundary. Every durable write
goes through an Ash action; Account isolation is enforced at the Phoenix edge,
in Ash policies, and in PostgreSQL row-level security.

**Ash domain backbone** — Resources are the durable type system and the policy
boundary. Message and document-version content is create-only, knowledge can
only be minted or merged by a pipeline actor, and lifecycle, audit, and usage
records are append-only. Generated migrations and resource snapshots stay in
sync with reviewed pgcrypto, pgvector, full-text-search, index, and RLS DDL.
→ `specs/architecture/ash-domain-backbone.md`

**Transactional writes, audit, and jobs** — Each ingest commits its raw
observation, a content-safe hash-chain audit event, a durable idempotency
record, and its AshOban job in one transaction. Eleven job lanes and four
Ash.Reactor flows cover extraction, dream-time reasoning, revalidation, expiry,
projection and entity refresh, connector sync, portability rebuild,
reconciliation, and governance continuations. Replays merge provenance instead
of duplicating knowledge, and a provider outage delays freshness rather than
losing observations.
→ `specs/architecture/transactional-writes-audit-jobs.md`

**Identity, tenancy, and RBAC** — AshAuthentication password/JWT identities for
humans and hashed per-Peer API keys for agents. Account is derived from the
authenticated identity, never from a header or request body. Role grants for
`account-admin`, `curator`, `member`, and `reader` inherit down the scope tree
and resolve deny-wins.
→ `specs/architecture/identity-tenancy-rbac.md`

**Gate A/B governance** — A versioned matrix over confidence, target level, and
sensitivity decides whether Gate A keeps, rejects, or defers an item and whether
Gate B may place it at the requested blast radius. The default is peer-level
provisional visibility plus human review; wider-scope proposals stay held and
out of retrieval, and upward personal attribution additionally requires
verified subject consent. Curator actions are reachable only by authenticated
human sessions — never by MCP or machine credentials. Peer self-view,
contest/redact, proportionate and strict erasure, revalidation, decay, and
escalation are all implemented.
→ `specs/architecture/gate-a-b-governance.md`

**Model layer and structured extraction** — One provider-neutral gateway over
ReqLLM with four Account-level roles: embedder, ingest extractor, dream
reasoner, and dialectic agent. Structured extraction uses Ash-derived schemas
with bounded validate-and-repair, resolves subject independently of source,
discounts hearsay, and records complete provenance. Embedding identity is
provider + model + version + dimensions; a mismatch takes the explicit re-embed
path and never silently substitutes vectors. One durable usage ledger meters
every call.
→ `specs/architecture/model-layer-structured-extraction.md`

**Documents, connectors, and sync** — Immutable hash-addressed document
versions over content-addressed local or S3-compatible blobs, MDEx and
ExtractousEx parsing, chunking and embedding for retrieval, and knowledge
extraction through the same pipeline and gates. Connector cursors advance only
after a page is durably handled; repeated hashes are no-ops; changed content
appends a version and supersedes stale derivations without rewriting history;
remote deletions become tombstones.
→ `specs/architecture/documents-connectors-sync.md`

**Retrieval, entity resolution, and context** — Independent Semantic, Lexical,
Temporal, SalienceRecency, and EntityMatch seed strategies plus hop-one
RelationExpand, combined by weighted reciprocal-rank fusion with optional
reranking. Named profiles are versioned, inherit nearest-wins, enforce a hard
deadline, and report contributed and dropped strategies. `search` defaults to
`:balanced`, `ask` to `:thorough`. Entity caches are internal and never
exposed. `get_context` assembles its budget from projections and stays
reasoning-free.
→ `specs/architecture/retrieval-entity-context.md`

**Skill readiness and procedural memory** — Human-authored, plain-versioned
skill requirement cards with a validated selector language, nearest-scope
requirement overrides, and a reasoning-free gap report. Required gaps block,
preferred gaps warn, and stale knowledge cannot satisfy a requirement.
→ `specs/architecture/skill-readiness-procedural-memory.md`

**Web console** — A LiveView surface every human role can sign in to: a scoped
dashboard, a knowledge explorer with a side-by-side retrieval preview that
shows which strategies contributed and which were dropped, a per-statement page
carrying provenance, extraction identity, lifecycle timeline, and
cross-references, a scope directory, a deterministic server-rendered graph of
scopes and statements, the raw observations and document versions behind it
all, and the subject's own consent, contest, redact, and erasure controls.
Curator decisions and promotion appear only for curators; the console writes
nothing itself and never exposes entity rows, vectors, or secrets.
→ `specs/architecture/browser-console.md`

**Portability, packaging, and operations** — Cross-platform Mix releases with a
checksum-pinned pg0 binary, supervised lifecycle, first-run migration,
stale-lock recovery, and an external-Postgres escape hatch; a non-root
container over stock Postgres; verified whole-Account logical archives;
readiness endpoints; exact metering; and redacted structured logs.
→ `specs/architecture/portability-packaging-operations.md`

**Evaluation, CI, and release readiness** — Reproducible reports for Cartulary
product scenarios, LoCoMo, LongMemEval, ConvoMem, and BEAM with full
provenance, strategy ablations, and committed correctness and citation floors;
blocking external-Postgres and packaged-pg0 CI lanes; release and container
builds; and fail-closed release checks.
→ `specs/architecture/evaluation-ci-release-readiness.md`

The complete, evidence-backed inventory is `specs/implementation-status.md`.

## Not yet implemented

Cartulary does not ship these, and
`specs/eval/surface-contract-inventory.json` marks them `unavailable` so the
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
`specs/roadmap/beta-roadmap.md`.

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
for operator-run Postgres. Install, configuration, Compose, and upgrade
procedures are in the published documentation:
<https://cartularyhq.github.io/cartulary/getting-started/>.

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
| `/mcp` | AshAi MCP endpoint |
| `/sign-in`, `/console/*` | Web console: dashboard, knowledge explorer and statement detail, scope directory, graph, sources, skills, personal self-governance, operations. Browser sessions only, every human role |
| `/governance` | Curator queue and skill-card authoring, curator or account-admin browser sessions only |

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
`docs/operations/backup-restore.md`. Both are published at
<https://cartularyhq.github.io/cartulary/operations/>.

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
`specs/eval/results/` are historical baseline evidence and are never relabelled
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
includes `x-trace-id`. The operator-facing guide is
<https://cartularyhq.github.io/cartulary/operations/observability/>;
`specs/observability/README.md` carries the measurement checklist and the eval
evidence workflow.

Traces and logs record ids, counts, profile names, model names, strategy names,
timings, token counts, and error classes. They never record raw messages,
prompts, answers, API keys, restricted knowledge, or secrets.

## Repository layout

| Path | What lives there |
| --- | --- |
| `lib/cartulary/` | The domain. One directory per subsystem; each Ash domain module lists the resources it owns. |
| `lib/cartulary/memory.ex` | The facade the HTTP layer calls: ingest, extract, search, ask, context. Start here. |
| `lib/cartulary/pipeline/` | The only writer of knowledge: extraction workflows, idempotency keys, advisory locks, reconciliation. |
| `lib/cartulary/governance/` | Gate A/B engine, curator actions, peer inline questions, erasure, lifecycle sweeper, hash-chain audit. |
| `lib/cartulary/retrieval/` | Seed strategies, SQL helpers, reciprocal-rank fusion, profiles, entity resolution, index rebuild. |
| `lib/cartulary/model/` | Provider-neutral gateway, the four model roles, structured generation, embeddings, provider adapters. |
| `lib/cartulary/documents/` | Immutable document versions, blob storage, parsing, connectors, document export. |
| `lib/cartulary/context/`, `skills/` | Reasoning-free projection assembly, and skill requirement cards with their gap report. |
| `lib/cartulary/portability/` | Whole-Account logical archive export, import, and audit-graph verification. |
| `lib/cartulary/eval/` | The evaluation harness: dataset adapters, scorers, run orchestration, report provenance. |
| `lib/cartulary_web/` | Phoenix router, controllers, plugs, and telemetry. |
| `lib/cartulary_web/console/`, `live/console_live/` | The browser console: its access rules, every read it performs, the graph layout, and the nine pages. |
| `lib/mix/tasks/` | Operator commands: eval runs, release checks, identity bootstrap, Account export/import. |
| `config/` | `config.exs` and per-environment files run at compile time; `runtime.exs` runs at boot and chooses the deployment mode. |
| `test/cartulary/` | Regression suites. The `f*` prefixes are frozen evidence identities, not phases; each module's moduledoc says what it pins. |
| `test/fixtures/` | Recorded provider cassettes and evaluation datasets that keep tests offline and deterministic. |
| `priv/repo/migrations/`, `priv/resource_snapshots/` | Generated by `mix ash.codegen` and then reviewed. Treated as historical once merged. |
| `rel/`, `scripts/`, `Dockerfile`, `compose.yml` | Release packaging, the checksum-pinned pg0 asset, launchers, and the container path. |
| `sdk/` | Transport-neutral skill-readiness helpers for Python and TypeScript. Not generated SDKs. |
| `docs/` | The published user documentation: setup, usage, operations, and how the system behaves. Built by `mkdocs.yml`. |
| `specs/` | Everything design-facing: blueprint specs, architecture notes, ADRs, design documents, the roadmap, implementation status, evaluation evidence. Not published. |

## Reading the code

Source files are the primary documentation here. Every module carries a
moduledoc that says what it is, what it owns, the invariants it guarantees, and
the mistakes callers must avoid; every public function documents its purpose,
return shape, and failure modes; comments explain *why*, not *what*. Nothing in
the source delegates its explanation to a spec — you should never have to open
`specs/` to understand a file. If you find a file that fails that test, it is a
defect worth reporting.

The fastest way in:

1. `lib/cartulary_web/router.ex` — every surface, and what each pipeline
   enforces.
2. `lib/cartulary/memory.ex` — the operations behind those routes.
3. `lib/cartulary/knowledge.ex` — the shape of the durable atom, and which
   actions only the pipeline may call.
4. `lib/cartulary/governance/engine.ex` — the rules that decide what is kept
   and how widely it is visible.
5. `lib/cartulary/retrieval/strategy.ex` — how it is read back, filtered, and
   fused.

The full convention, including what may not appear in a comment, is the
"Coding conventions" section of `AGENTS.md`. It applies to human contributors
and coding agents alike.

## Documentation map

Documentation lives in exactly two trees, and they do not overlap.

**`docs/` — how to use it.** Setup, usage, operations, and explanations of how
the running system behaves, with diagrams. Published to
<https://cartularyhq.github.io/cartulary/> by `.github/workflows/docs.yml`.

| Section | What it covers |
| --- | --- |
| `docs/getting-started/` | Release, container, and source installs; the quickstart tutorial. |
| `docs/concepts/` | How it works: memory model, pipeline, gates, retrieval, documents, skills, isolation, deployment modes. |
| `docs/guides/` | Task-oriented usage: authentication, the web console, ingest, search and ask, context, readiness, curation, self-governance, MCP, SDK helpers. |
| `docs/operations/` | Upgrades, health and cost, observability, backup and restore, export and import. |
| `docs/reference/` | HTTP API, configuration, Mix tasks, contract versions, glossary, limitations. |

**`specs/` — why it is built this way.** Design material, not published.
Source files stand on their own; these documents exist for the reasoning
*behind* the code — decisions, trade-offs, evidence, and process.

| Document | What it is for |
| --- | --- |
| `AGENTS.md` | The operating contract for agents and contributors, including the coding conventions. Read it first. |
| `CONTRIBUTING.md` | How to develop here: workflow, checks, review expectations. |
| `specs/memory-system-*.md` | The blueprint: functional requirements, architecture and NFRs, product blueprint, evaluation framework. |
| `specs/architecture/free-core-architecture.md` | Target decomposition, abstraction layers, durable-versus-derived rules, contract version identities. |
| `specs/architecture/` | One note per implemented capability. |
| `specs/adr/` | Architecture decision records. |
| `specs/design/` | Dated design documents behind specific ADRs. |
| `specs/roadmap/beta-roadmap.md` | The only roadmap: what is left to build, with acceptance criteria. |
| `specs/implementation-status.md` | What runs today, its verification evidence, and its real limitations. |
| `specs/eval/` | Evaluation harness, thresholds, surface inventory, historical results. |
| `specs/observability/` | Measurement discipline and the evidence workflow. |
| `specs/process/` | Versioning policy and the release checklist. |
| `specs/security/` | Security notes. |

A change that alters anything a user or operator can see updates the matching
`docs/` page in the same patch. The mapping is tabulated in the "Documentation
layout" section of `AGENTS.md`.

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
