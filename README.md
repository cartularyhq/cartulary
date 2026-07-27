# Cartulary

Cartulary is an Elixir/Ash/Phoenix/Oban memory system prototype for governed
agent memory on the BEAM. The current repository state is a local proof of
concept, not a finished product architecture.

The POC can run against local Postgres from pg0 and use an OpenAI-compatible
model endpoint such as OpenRouter with `openai/gpt-oss-120b`.

## What Runs Today

- Phoenix API skeleton with health, ingest, search, ask, context, and knowledge
  endpoints.
- Postgres schema for accounts, peers, scopes, sessions, raw messages,
  knowledge items, and lifecycle events.
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

Read that document before treating any POC code as an architectural precedent.

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

- Core writes are implemented in a narrow service module with SQL, while the
  long-term target is Ash resources, actions, policies, and data-layer
  contracts.
- Oban is wired directly for the POC; AshOban and full transactional workflow
  ownership remain to be added.
- Retrieval is Postgres FTS plus simple temporal and salience/recency queries;
  pgvector is enabled but semantic embeddings and ANN indexes are not yet
  implemented.
- LoCoMo, LongMemEval, and BEAM coverage is a smoke harness only, not full
  benchmark import, scoring, or regression gating.
- Account identity is derived from an HTTP header for local testing; production
  identity, RLS, authorization, consent, and full Gate B governance are not
  implemented.

## Checks

For code changes, run:

```bash
mix deps.get
mix format --check-formatted
mix compile --warnings-as-errors
mix test
```

Credo, Dialyzer, and Sobelow are not configured yet in the current POC.
