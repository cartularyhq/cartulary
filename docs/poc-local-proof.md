# Local POC Implementation Log

Date: 2026-07-28

This document records what was actually built for the local proof of concept,
what corners were cut to get there, and what must be refactored before the POC
can be treated as the durable Cartulary architecture.

## Implemented

- Created a Phoenix API application inside the existing repository.
- Added Postgres-only Ecto/AshPostgres configuration for local development and
  tests.
- Added migrations for accounts, peers, scopes, sessions, raw messages,
  knowledge items, lifecycle events, Oban tables, Postgres FTS, `pgcrypto`, and
  `pgvector`.
- Added Ash domains/resources as the declared domain boundary for the POC data
  model.
- Completed roadmap F1 with nine configured Ash Domains and the full
  26-resource backbone, authoritative Ash actions/policies, attribute tenancy,
  PostgreSQL RLS, generated resource snapshots/migrations, and deterministic
  action/DB isolation tests.
- Completed roadmap F2 with the `PipelineRun` resource, transactional
  observation/audit/AshOban writes, deterministic keys, per-Account hash
  chains, replay-safe extraction, Ash.Reactor continuations, and
  reconciliation.
- Completed roadmap F3 with AshAuthentication password/JWT and API-key
  identities, linked Peer assurance, one authenticated community Account,
  Account RLS for credentials, and inherited deny-wins scope RBAC.
- Completed roadmap F4 with the versioned Gate A/B matrix, provisional and held
  states, curator/peer validation queues, target-specific personal consent,
  immutable decision/lifecycle/audit evidence, a human-only LiveView queue,
  peer self-service and erasure, dream-time revalidation/decay, and AshAi MCP
  inline validation with transcript assurance.
- Completed roadmap F5 with four Account-level model roles, a ReqLLM-backed
  provider behavior, local Ortex/ONNX and API embedding adapters, Ash-derived
  structured extraction/reasoning schemas, bounded repair, full model
  provenance, exact usage events, and cassette-injected capability tests.
- Completed roadmap F6 with a tenth Documents Domain and a 38-resource durable
  boundary, immutable document versions, content-addressed Local/S3 blob
  adapters, MDEx/ExtractousEx parsing, TextChunker and bitcrowd/rag chunk
  embeddings, incremental connector sync, supersession/tombstones, and
  checksum-verified document export/import and erasure.
- Completed roadmap F7 with six independent retrieval strategies, two-phase
  deadline-bounded fan-out, weighted RRF, optional reranking, `f7-1` profiles,
  pgvector/FTS indexes, replay-safe vector/entity/projection rebuild, internal
  entity resolution, and projection-backed reasoning-free context assembly.
- Completed roadmap F9 with plain-versioned authored skill cards, the strict
  `f9-1` selector language, nearest-scope requirement overrides, reasoning-free
  lifecycle-aware gap reports, HTTP/MCP exposure, governance authoring/review,
  and provider-neutral TypeScript/Python elicitation helpers.
- Completed roadmap F11 with deterministic external-Postgres and packaged-pg0
  gates, release/container builds, versioned LoCoMo/LongMemEval/ConvoMem/BEAM
  and Cartulary eval reports, strategy ablations, token/RAG-triad evidence,
  semantic versioning, changelog discipline, and fail-closed release checks.
- Converted `Cartulary.Memory` durable reads and writes to Ash actions while
  preserving the F0 shapes and intentionally versioning lifecycle semantics to
  `f4-1`, extraction to `f5-1`, and retrieval/context to `f7-1`. The obsolete
  `Cartulary.Memory.Query` transition helper has been removed.
- Added `Cartulary.Memory` as the POC write/read path for message ingestion,
  pipeline extraction, knowledge insertion, search, ask, and context reads.
- Added a pipeline extractor that accepts only schema-valid structured output,
  resolves subject separately from source, discounts hearsay, proposes temporal
  fields/update operations, and retries provider failures through AshOban.
- Added provider-neutral runtime and persisted role configuration, defaulting
  generation roles to OpenRouter `openai/gpt-oss-120b`, embeddings to local
  `BAAI/bge-small-en-v1.5`, and deterministic generation only to explicit
  test/local fallback.
- Added a Phoenix JSON API:
  - `GET /api/health`
  - `POST /api/v1/ingest`
  - `POST /api/v1/search`
  - `POST /api/v1/ask`
  - `POST /api/v1/context`
  - `POST /api/v1/readiness`
  - `GET /api/v1/knowledge`
- Froze the `poc-0` behavior as roadmap phase F0:
  - HTTP contracts for all six endpoints.
  - Database-backed contracts for caller Account selection, downward scope
    inheritance, raw message persistence, pipeline-created knowledge, and
    lifecycle insertion.
  - A negative contract proving agents have no direct knowledge-write route.
  - Stable hashes and normalized IDs for the tiny Cartulary, LoCoMo,
    LongMemEval, and BEAM fixtures.
  - Test database isolation from a development `DATABASE_URL` loaded through
    `.env`.
- Added a small smoke eval task:

```bash
mix cartulary.eval.smoke --profile balanced --account eval-poc
```

The smoke task includes tiny LoCoMo, LongMemEval, and BEAM-style examples and
can write a JSON report with `--output`.
- Added full benchmark fixture ingestion and deterministic scoring:

```bash
mix cartulary.eval.benchmark --benchmark locomo --dataset path/to/locomo10.json
mix cartulary.eval.benchmark --benchmark longmemeval --dataset path/to/longmemeval_s_cleaned.json
mix cartulary.eval.benchmark --benchmark beam --dataset path/to/beam.json
```

The benchmark runner normalizes LoCoMo, LongMemEval, BEAM-style, and local
Cartulary JSON fixtures into one eval case shape, ingests turns through
`Cartulary.Memory`, asks through the real POC retrieval/answer path, resolves
citations back to benchmark evidence references, and reports per-question,
per-category, latency, citation, abstention, token-F1, and BEAM scale-curve
metrics.

## Verified

The local POC was verified against pg0-backed Postgres and the configured
OpenRouter key.

- `mix deps.get` passed.
- `mix format --check-formatted` passed.
- `mix compile --warnings-as-errors` passed.
- `mix ecto.migrate` passed, including `CREATE EXTENSION IF NOT EXISTS vector`.
- `mix test` passed with 65 tests (including two property tests), covering the
  F0 HTTP, persistence, inheritance, Account-selection, pipeline-write,
  lifecycle, deterministic fallback, and eval-fixture contracts; the F1 Ash
  action/RLS suite; F2 transaction/audit/AshOban/Reactor/replay/provider-outage;
  F3 password/API-key, single-Account, opaque-failure, cross-link, and property
  suites; F4 matrix, consent, curator/MCP separation, inline assurance,
  revalidation/decay, LiveView, and erasure; F5 bounded structured repair,
  subject/temporal extraction, provenance, all provider capabilities, re-embed
  guards, exact usage, and retryable outage behavior; and F6 dual document
  ingest, native parsing, pinned chunks, sync/no-op/supersession/tombstones,
  portability, erasure/rebuild, independent provenance, and secret rejection;
  plus F7 strategy/profile contracts, vector/FTS indexes, semantic and
  relation/entity retrieval, Account/scope filtering, deadline reporting,
  internal entity opacity, and model-free context caching.
- `mix ash.codegen --check` passed with no resource/snapshot drift.
- The F1 suite passed against a newly created partitioned test database,
  exercising the complete migration chain from an empty database.
- The F2 suite passed with a real manual-mode Oban queue drain through the
  generated AshOban worker and ingest Reactor.
- The combined F1/F2 suite passed against a newly created `f2` partitioned test
  database, exercising the complete migration chain from an empty database.
- The complete F0-F5 suite passed against a newly created `f5_final`
  partitioned test database, exercising the complete migration chain from an
  empty database.
- The complete F0-F6 suite passed against a newly created `f6_final`
  partitioned test database, exercising the complete migration chain from an
  empty database.
- The F7 migration and complete F0-F7 suite passed against the configured test
  Postgres and a newly created `f7_final` partitioned database.
- F10 adds a second stock-Postgres lane through `compose.yml`, the
  `CARTULARY_TEST_DATABASE_URL` override, a packaged pg0 startup/readiness
  smoke, and a real fresh-database Account export/import round trip.
- `mix credo --strict` passed with no issues.
- `mix dialyzer` passed with 0 errors.
- `mix sobelow --config` passed with no findings after three targeted
  POC false-positive skips:
  - local benchmark fixture reads in `Cartulary.Eval.Adapter`.
  - the read-only static retrieval data layer in `Cartulary.Retrieval.Store`.
  - the static UUID-only message-to-Account bootstrap lookup in
    `Cartulary.DataLayer`.
- F11 raised the suite to 83 passing tests (81 examples plus two properties);
  `mix ash.codegen --check`, formatting, warnings-as-errors compilation, Credo,
  Dialyzer, and Sobelow passed. The deterministic `f11-1` release matrix covered
  Cartulary, LoCoMo, LongMemEval, ConvoMem, and BEAM plus eight ablations,
  validated report provenance, met every committed correctness/citation floor,
  and passed the semantic-version/changelog release check for `0.2.0`.
- `mix cartulary.eval.smoke --profile balanced --account eval-openrouter-current`
  ingested 3 messages and answered all 3 smoke questions with citations.
- `mix cartulary.eval.benchmark --dataset test/fixtures/eval/cartulary-smoke.json --benchmark cartulary --profile balanced --account eval-f7-final-2 --run-id f7-final-2 --no-model`
  ingested 2 messages and scored 1 deterministic `f7-1` question through the
  full benchmark runner with accuracy `1.0`, citation hit rate `1.0`, contains
  accuracy `1.0`, mean token F1 `0.4`, and retrieval latency `9 ms`. The
  operator-supplied local embedding artifact was not configured, so the
  background projection refresh remained retryable as required by F5 while the
  no-model lexical/temporal retrieval path completed.
- Minimal LoCoMo, LongMemEval, and BEAM fixtures were run through the full
  benchmark runner and wrote repository-local JSON reports. Results are
  recorded in `docs/eval/minimal-benchmark-results.md`.
- The Cartulary, LoCoMo, LongMemEval, and BEAM F0 fixtures match the committed
  `poc-0` hash and normalization baseline in
  `test/fixtures/eval/poc-contract-baseline.json`.
- `GET /api/health` returned status `ok` and contract `f5-1`.
- HTTP ingest and ask were verified locally; the ask response returned a cited
  knowledge item extracted by `openai/gpt-oss-120b`.

Credo, Dialyzer, and Sobelow are configured for local checks. They are not yet
wired as CI branch-protection gates.

## Corners Cut

These shortcuts are acceptable only for the local POC.

- **Later pipeline behavior is parked behind F2 continuations.** AshOban and
  Ash.Reactor now own durable execution and the POC-compatible synchronous
  response is replay-safe. F4 now implements governance revalidation, expiry,
  validation continuation, and transcript answer-correlation semantics. F6
  implements document connectors and the document portability component; F7
  implements vector/entity/projection refresh; F10 implements verified full
  Account archives and rebuild scheduling.
- **Human identity is local free-core identity.** F3 now uses
  AshAuthentication password/JWT identities and per-Peer API keys. Enterprise
  SSO/SAML/SCIM, multi-Account provisioning, advanced RBAC administration, and
  channel-linking UX remain later licensed/governance work.
- **Model deployment assets remain operator-supplied.** F5 supplies the
  provider-neutral ReqLLM seam and local Ortex/ONNX execution, but does not
  download or package ONNX/tokenizer artifacts, certify every ReqLLM provider,
  or add an in-engine multi-provider cascade.
- **Committed eval data remains minimal.** F11 supplies LoCoMo, LongMemEval,
  ConvoMem, BEAM, and Cartulary adapters; deterministic correctness/citation,
  RAG-triad, token-efficiency, latency, category, scale, and ablation reports;
  held-out tuning discipline; release thresholds; and CI gates. The committed
  fixtures are smoke-scale and are not presented as upstream-scale scores.
  Independent live-model judge and large-corpus results remain release evidence
  to produce when protected provider credentials and upstream datasets exist.
- **pg0 packaging is operational.** F10 pins and checksum-verifies pg0,
  supervises its release lifecycle, migrates on first run, checks ports/data
  directories, and retains the external-Postgres mode. ONNX/tokenizer
  artifacts remain operator-supplied by design.
- **Retrieval tuning remains evidence work.** F7 provides versioned profiles,
  raw internal ablations, deadline-disabled evals, and complete strategy
  instrumentation. F11 enforces the held-out split and release floors; actual
  fusion-weight changes still require upstream-scale held-out evidence.
- **Surfaces are partial.** F4 adds the curator LiveView, peer self-service API,
  and AshAi MCP tools. F6 supplies the internal document/connector/portability
  boundary; F9 adds readiness HTTP/MCP actions, card governance UI, and
  transport-neutral SDK helper modules; F10 adds operator Account export/import
  commands. AshJsonApi, complete generated SDKs, gateway proxy, connector
  administration, and an Account archive administration UI remain later
  phases.
- **Tests retain the POC regression floor.** F0 now covers the six HTTP endpoints,
  caller-header Account selection, downward scope inheritance, message and
  knowledge persistence, creation lifecycle events, deterministic extraction,
  eval normalization/scoring, and the missing direct knowledge-write route.
  F1 adds deterministic Ash action-policy and non-owner PostgreSQL RLS tests.
  F2 adds transactional rollback, actual AshOban extraction, replay,
  hash-chain, reconciler, and provider-outage persistence coverage. F3 adds
  identity, Account-wall, inheritance/deny, cross-link, and opaque-failure
  coverage. F4 adds gate, consent, curator separation, revalidation, and
  erasure coverage. F5 adds replayed extraction repair, all five injectable
  provider capabilities, exact usage, embedder migration, and outage/retry
  behavior. F6 covers document dual ingest, pinned chunks, connector hash
  no-ops, changed-version supersession, tombstones, cursor progression,
  portability, erasure, rebuild, and secret rejection. F7 covers strategy,
  fusion, projection, entity privacy, and semantic retrieval contracts. F9
  covers selector inheritance, version/audit behavior, blocker/warning
  semantics, stale lifecycle handling, and all shipped readiness surfaces. F10
  covers archive exclusions/integrity, tamper rejection, readiness, exact edge
  metering, packaging pins, and pg0/external-Postgres lanes. F11 turns those
  contracts into blocking CI, adds report/version/surface/release contracts,
  and builds release/container artifacts. The suite does not claim broad
  live-provider certification.

## Required Refactors After POC

1. Split retrieval into strategy modules with explicit behaviours, profile
   versions, weights, per-strategy evidence, deadline budgets, async fan-out,
   dropped-strategy reporting, and ablation support.
2. Complete embedding persistence and retrieval: add the `pgvector`
   column/index, backfill jobs, semantic strategy, and rebuild/parity evidence
   around the F5 pinned embedder.
3. Run upstream-scale LoCoMo, LongMemEval, ConvoMem, and BEAM datasets plus an
   independent-family live judge through the F11 report contract; retain the
   results as release evidence rather than treating smoke fixtures as scores.
4. Add durable projections and rebuildable caches for context reads, including
   session summaries, scope cards, peer profiles, and derived indexes.
5. Expand tests beyond F0-F6 into applied dream-time deductions, projection
   builds, semantic retrieval fusion, broader provider
   compatibility, and release eval behavior.
6. Configure the documented F11 job names as GitHub required checks; repository
   rulesets remain a maintainer-owned external setting.

## Current Local Commands

For a downloaded release, one command starts the pinned pg0 instance, migrates,
and serves:

```bash
bin/server
```

For source development, create local configuration and provide the Postgres
server selected by `DATABASE_URL`:

```bash
cp .env.example .env
```

Run setup and checks:

```bash
mix deps.get
mix ecto.migrate
mix format --check-formatted
mix compile --warnings-as-errors
mix test
```

Run the smoke eval:

```bash
mix cartulary.eval.smoke --profile balanced --account eval-poc
```

Run the focused frozen POC contract:

```bash
mix test \
  test/cartulary/poc_contract_test.exs \
  test/cartulary_web/controllers/memory_controller_test.exs \
  test/cartulary/eval/fixture_contract_test.exs
```

Start the local API:

```bash
mix phx.server
```

The server listens on `http://localhost:4000`.
