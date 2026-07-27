# Cartulary

Cartulary is an Elixir/Ash/Phoenix/Oban memory system prototype for governed
agent memory on the BEAM. The current repository state combines the frozen
local POC contract with the implemented F1 Ash Domain Backbone and F2
Transactional Writes, Audit, And Jobs plus F3 Identity, Tenancy, And Basic
RBAC and F4 Real Gate A/B Governance; it is not yet a finished product
architecture.

The POC can run against local Postgres from pg0 and use an OpenAI-compatible
model endpoint such as OpenRouter with `openai/gpt-oss-120b`.

The target free self-host core is documented in
`docs/roadmap/free-core-roadmap.md`. That plan starts from the POC handoff,
keeps the ARCH directive of one codebase and identical guarantees, and lays out
the Ash/Phoenix/Oban architecture, abstraction layers, decomposition, migration
phases, and feature coverage needed for a complete single-Account community
solution.

Roadmap phases F0 through F4 are complete. F0 response shapes, persistence,
scope inheritance, pipeline-only knowledge writes, and tiny eval fixtures
remain regression floors. F4 intentionally versions lifecycle behavior to
`f4-1`: new proposals are provisionally peer-visible or held for governance
instead of being auto-activated. Nine Ash Domains and 36 Resources own the
durable boundary.

## What Runs Today

- Phoenix API skeleton with health, ingest, search, ask, context, and knowledge
  endpoints.
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
  limits. Curator actions are not exposed to MCP or machine credentials.
- AshAuthentication password/JWT identities for humans and hashed API-key
  identities for agents, linked to Peers with assurance levels.
- One authenticated community Account, enforced by a database free-edition
  slot, with inherited allow/deny role grants for account-admin, curator,
  member, and reader.
- Transactional message/document ingestion that commits a content-safe
  hash-chain audit event, durable idempotency record, and AshOban job together.
- Eleven AshOban lanes for extraction, dream-time, revalidation, expiry,
  projection/entity refresh, connector sync, portability rebuild,
  reconciliation, and governance continuations.
- Ash.Reactor flows for ingest extraction, dream-time reasoning, validation
  continuation, and transcript answer correlation.
- Per-Account SHA-256 audit chains and an Account-scoped reconciler for raw
  messages not yet processed.
- PostgreSQL RLS on every Account-scoped table, plus generated AshPostgres
  snapshots/migrations, foreign keys, FTS, and supporting indexes.
- pgcrypto, Postgres FTS, Oban tables, and pgvector extension migration.
- A single POC memory service that writes raw messages, extracts knowledge
  through the pipeline, retrieves candidates, and returns grounded answers with
  citations.
- OpenRouter-compatible model client configured from `.env`.
- Built-in smoke harness for tiny LoCoMo, LongMemEval, and BEAM-style memory
  paths:

```bash
mix cartulary.eval.smoke --profile balanced --account eval-poc
```

## Local Setup

Prerequisites:

- Elixir 1.17 or newer.
- A local pg0 binary. The current POC expects a Postgres-compatible server on
  `localhost:5432`.

Install pg0 into `/private/tmp` on macOS ARM64:

```bash
curl -fL https://github.com/vectorize-io/pg0/releases/latest/download/pg0-darwin-aarch64 -o /private/tmp/pg0
chmod +x /private/tmp/pg0
```

For another OS or CPU architecture, download the matching binary from the pg0
releases page:

```bash
https://github.com/vectorize-io/pg0/releases
```

Create your local environment file:

```bash
cp .env.example .env
```

`OPENROUTER_API_KEY` is optional. If it is blank, the POC uses a deterministic
fallback extractor so local tests and smoke runs still work. To use OpenRouter
or another OpenAI-compatible endpoint, set:

```bash
OPENROUTER_API_KEY=...
CARTULARY_OPENAI_COMPAT_BASE_URL=https://openrouter.ai/api/v1
```

Start Postgres through pg0:

```bash
/private/tmp/pg0 start --name cartulary --port 5432 --username postgres --password postgres --database cartulary_dev
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
routes. The MCP endpoint is `/mcp`.

Run the local smoke eval:

```bash
mix cartulary.eval.smoke --profile balanced --account eval-poc
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

## F0 Contract And F4 Lifecycle Version

F0 freezes behavior, not the POC's internal design. `Cartulary.Memory` is now a
compatibility facade over authoritative Ash actions. F2 owns transactional
audit/AshOban behavior; the only remaining static retrieval SQL is the named
F7 transition helper in `Cartulary.Memory.Query`.

The contract evidence covers:

- all six HTTP endpoints: health, ingest, search, ask, context, and knowledge;
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
`f4-1`; extractor and retrieval profile identifiers remain `poc-0` until their
F5/F7 migrations.

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

- Core durable reads and writes now use Ash. The POC retrieval strategies still
  use static parameterized SQL in the explicit F7 transition helper.
- F2 provides the durable lanes for dream-time, lifecycle, connector,
  portability, and projection work. Their domain behavior remains owned by
  F4/F5/F6/F9/F12 and currently stops at typed continuation seams.
- Retrieval is Postgres FTS plus simple temporal and salience/recency queries;
  pgvector is enabled but semantic embeddings and ANN indexes are not yet
  implemented.
- LoCoMo, LongMemEval, and BEAM fixture import/scoring exists for the POC, but
  upstream judge parity, ablation matrices, release thresholds, and backend
  parity evidence are not implemented.
- F3 identity and basic RBAC are implemented. Human governance UI separation,
  consent, validation queues, and the full Gate A/B lifecycle remain F4 work.

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
