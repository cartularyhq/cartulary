# Local POC Implementation Log

Date: 2026-07-27

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
- Added `Cartulary.Memory` as the POC write/read path for message ingestion,
  pipeline extraction, knowledge insertion, search, ask, and context reads.
- Added a pipeline extractor that uses an OpenAI-compatible endpoint when a key
  is configured and a deterministic fallback when it is not.
- Added OpenRouter-compatible configuration from `.env`, defaulting model roles
  to `openai/gpt-oss-120b`.
- Added a Phoenix JSON API:
  - `GET /api/health`
  - `POST /api/v1/ingest`
  - `POST /api/v1/search`
  - `POST /api/v1/ask`
  - `POST /api/v1/context`
  - `GET /api/v1/knowledge`
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
- `mix test` passed with 9 tests.
- `mix credo --strict` passed with no issues.
- `mix dialyzer` passed with 0 errors.
- `mix sobelow --config` passed with no findings after two targeted
  POC false-positive skips:
  - local benchmark fixture reads in `Cartulary.Eval.Adapter`.
  - the internal static-SQL helper in `Cartulary.Memory`.
- `mix cartulary.eval.smoke --profile balanced --account eval-openrouter-current`
  ingested 3 messages and answered all 3 smoke questions with citations.
- `mix cartulary.eval.benchmark --dataset test/fixtures/eval/cartulary-smoke.json --benchmark cartulary --profile balanced --account eval-benchmark-local --run-id docs-poc-check-2 --no-model`
  ingested 2 messages and scored 1 deterministic question through the full
  benchmark runner.
- Minimal LoCoMo, LongMemEval, and BEAM fixtures were run through the full
  benchmark runner and wrote repository-local JSON reports. Results are
  recorded in `docs/eval/minimal-benchmark-results.md`.
- `GET /api/health` returned status `ok`.
- HTTP ingest and ask were verified locally; the ask response returned a cited
  knowledge item extracted by `openai/gpt-oss-120b`.

Credo, Dialyzer, and Sobelow are configured for local checks. They are not yet
wired as CI branch-protection gates.

## Corners Cut

These shortcuts are acceptable only for the local POC.

- **Ash boundary is mostly declarative.** Resources exist, but the operational
  write/read path in `Cartulary.Memory` uses direct SQL through Ecto. This keeps
  the POC small but bypasses Ash actions, changesets, policies, validations,
  and authorization.
- **Oban is wired directly.** The target is Oban through AshOban with stronger
  workflow ownership. The POC can enqueue extraction, but defaults to synchronous
  extraction so smoke runs are deterministic.
- **Gate B is a placeholder.** The POC auto-activates knowledge from confidence
  and sensitivity fields. It does not implement the full governed promotion
  matrix, consent handling, blast-radius checks, peer review, or manual
  validation.
- **Account isolation is local-only.** API account selection comes from
  `x-cartulary-account-key`. The body cannot override it, but there is no real
  identity provider, authz policy, RLS, or key ownership model.
- **Retrieval is inline and partial.** Lexical, temporal, and salience/recency
  strategies are implemented as SQL branches in one module with RRF fusion.
  There are no strategy behaviours, per-strategy budgets, async fan-out,
  deadline dropping, reranking, or configurable weights yet.
- **pgvector is enabled but not used.** The migration creates the extension, but
  there is no embedding column, embedding model role, ANN index, backfill job,
  semantic strategy, or vector parity evidence.
- **Model abstraction is thin.** The POC uses `Req` directly against an
  OpenAI-compatible endpoint. The target provider-neutral seam over ReqLLM,
  local Ortex/ONNX embeddings, and self-hosted models is not implemented.
- **Evaluation is still POC-grade.** Full LoCoMo, LongMemEval, and BEAM-style
  fixture importers now exist, with deterministic answer/citation scoring,
  category metrics, latency summaries, and BEAM scale curves. Missing pieces are
  upstream LLM-judge parity, held-out weight tuning, broader strategy-ablation
  matrices, release thresholds, CI gates, and backend parity evidence.
- **pg0 is manually launched.** The local test used `/private/tmp/pg0`; the
  release does not yet download, pin, supervise, health-check, or recover pg0.
- **Lifecycle audit is minimal.** The POC writes creation state transitions, but
  does not yet model review, supersession, expiry, revalidation, consent changes,
  or cross-scope promotion events.
- **Projection layer is absent.** Profiles, scope cards, session summaries,
  peer profiles, ETS caches, `persistent_term` caches, and rebuild jobs are not
  implemented.
- **Surfaces are minimal.** There is no LiveView, AshJsonApi, MCP server,
  gateway proxy, admin UI, import UI, or export UI.
- **Tests are thin.** Current tests cover the deterministic extractor and
  generated Phoenix error JSON. They do not yet cover database transactions,
  account isolation, HTTP endpoints, Oban async extraction, lifecycle audit,
  retrieval scoring, or model failure modes.

## Required Refactors After POC

1. Move raw SQL write/read behavior into Ash resources, actions, changesets,
   validations, policies, and query APIs while preserving pipeline-only
   knowledge writes.
2. Add AshOban integration and make extraction, lifecycle, audit writes, and
   job enqueueing transactionally owned by the Ash action layer.
3. Implement real identity-derived accounts, authorization policies, Postgres
   RLS, and tests proving request bodies cannot cross account boundaries.
4. Replace the placeholder Gate B with governed lifecycle actions for proposal,
   validation, promotion, demotion, supersession, expiry, revalidation, consent,
   and audit.
5. Split retrieval into strategy modules with explicit behaviours, profile
   versions, weights, per-strategy evidence, deadline budgets, async fan-out,
   dropped-strategy reporting, and ablation support.
6. Add embeddings: provider-neutral embedding role, local/offline embedding
   path, `pgvector` column/index, backfill jobs, semantic retrieval, and rebuild
   evidence.
7. Replace the direct OpenRouter client with the intended provider-neutral model
   seam while preserving OpenAI-compatible endpoints and local model options.
8. Harden the LoCoMo, LongMemEval, and BEAM eval runner with upstream LLM-judge
   parity, held-out tuning discipline, strategy-ablation matrices, regression
   thresholds, generated release reports, and operator-run Postgres parity
   evidence.
9. Pin and package pg0 for local mode, supervise its lifecycle from the release,
   handle port conflicts and stale data directories, and document the external
   Postgres escape hatch.
10. Add durable projections and rebuildable caches for context reads, including
    session summaries, scope cards, peer profiles, and derived indexes.
11. Expand tests to cover migrations, HTTP surfaces, Ash actions, policies, RLS,
    Oban jobs, model fallback, retrieval fusion, lifecycle audit, and eval smoke
    reports.
12. Wire the configured static analysis/security lanes into CI and branch
    protection when the repository automation is ready to maintain them.

## Current Local Commands

Create local configuration:

```bash
cp .env.example .env
```

Install pg0 into `/private/tmp` on macOS ARM64:

```bash
curl -fL https://github.com/vectorize-io/pg0/releases/latest/download/pg0-darwin-aarch64 -o /private/tmp/pg0
chmod +x /private/tmp/pg0
```

Start pg0:

```bash
/private/tmp/pg0 start --name cartulary --port 5432 --username postgres --password postgres --database cartulary_dev
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

Start the local API:

```bash
mix phx.server
```

The server listens on `http://localhost:4000`.
