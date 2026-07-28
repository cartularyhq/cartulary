<!-- SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0 -->

# Community Operations

This is the operator entry point for the F10 community release. The same Mix
release supports embedded pg0 and operator-run Postgres; database location does
not select different product behavior.

## Install

Download and unpack the release built for the host platform, then run:

```bash
bin/server
```

On Windows:

```powershell
bin\server.bat
```

The launcher creates `~/.cartulary`, generates a private signing secret,
starts the checksum-pinned pg0 binary, creates its Postgres cluster, runs all
migrations, and starts Phoenix. Override `CARTULARY_DATA_ROOT`, `PORT`, or
`CARTULARY_PG0_PORT` before the first start when the defaults are unsuitable.
The release fails before accepting traffic if the port is occupied or the data
directory and configuration are unhealthy.

Build platform releases from source with `./scripts/package-release` on Unix
or `scripts\package-release.ps1` on Windows. Both download the exact asset
named in `rel/pg0/VERSION`, verify it against `rel/pg0/checksums.txt`, and stage
it only for release assembly.

For a container install:

```bash
docker compose up --build
```

This runs the app against stock Postgres and exposes the app at
`http://127.0.0.1:4000`. Add local tracing and metrics with:

```bash
CARTULARY_OTEL_ENABLED=true docker compose --profile observability up --build
```

Replace the compose signing secret and database password before exposing that
stack beyond a developer machine.

## External Postgres

Point the unpacked release at an operator-run PostgreSQL 18 server with
pgvector available:

```bash
export CARTULARY_DATABASE_MODE=external
export DATABASE_URL='ecto://user:password@db.example/cartulary'
export CARTULARY_AUTO_MIGRATE=true
export CARTULARY_AUTH_SIGNING_SECRET='at-least-64-random-bytes...'
export CARTULARY_BLOB_ROOT=/absolute/durable/blob/path
bin/cartulary start
```

Set `CARTULARY_AUTO_MIGRATE=false` when change control requires a separate
step, then run `bin/migrate` before starting the release. Account identity is
still derived from credentials; no deployment variable changes tenancy rules.

## Upgrade

1. Create and verify both the database and blob backups in
   `backup-restore.md`.
2. Export the Account archive as an independent logical recovery check.
3. Stop the old release cleanly.
4. Unpack the new release beside the old one; do not overwrite the old
   executable tree or data directory.
5. Reuse the same environment and durable data/blob paths.
6. Run `bin/migrate`, then start the new release.
7. Require `GET /api/ready` to return 200 and exercise an authenticated read.
8. Retain the old executable and pre-upgrade backups until verification
   completes.

Database migrations are forward operations. Rollback means restoring the
pre-upgrade database and blob snapshot together, then starting the prior
release; do not run an old release against a newly migrated database.

## Runtime configuration

The important deployment variables are:

| Variable | Meaning |
| --- | --- |
| `CARTULARY_DATABASE_MODE` | `pg0` or `external` |
| `DATABASE_URL` | Required only for external mode |
| `CARTULARY_AUTO_MIGRATE` | Run migrations as a supervised startup step |
| `CARTULARY_PG0_*` | Embedded binary, instance, data path, port, credentials |
| `CARTULARY_BLOB_ADAPTER` | `local` or `s3` |
| `CARTULARY_BLOB_ROOT` | Absolute local blob path |
| `CARTULARY_S3_*` | S3 bucket, prefix, and compatible endpoint |
| `CARTULARY_MODEL_*` | Generation provider/model identities |
| `CARTULARY_EMBEDDING_*` | Embedding provider, identity, dimensions, artifacts |
| `CARTULARY_BUDGET_LIMITS_JSON` | Daily dream-time admission token limits |
| `CARTULARY_MODEL_COSTS_JSON` | Operator rates in USD per million tokens |
| `CARTULARY_OTEL_*`, `OTEL_*` | Content-safe OpenTelemetry controls |

The complete development example is `.env.example`. Production disables the
deterministic generation fallback. Ortex artifacts are intentionally
operator-supplied and offline: pin the ONNX model and tokenizer paths, and bump
the embedding version whenever artifacts, pooling, or dimensions change.

## Health and observability

- `GET /api/health`: stable liveness response.
- `GET /api/ready`: database, Oban, queues, and model-role readiness.
- `GET /api/v1/operations/costs`: authenticated account-admin usage/storage
  totals and configured estimate.
- Every HTTP response carries `x-trace-id`; an incoming W3C trace id is
  retained.

Use `docs/observability/README.md` for telemetry attributes, dashboards, trace
correlation, and the content-safety contract.

## Product surfaces

- Gateway/API and authentication: README API examples and `/api/v1`.
- MCP: `/mcp`; machine identities can ingest observations and read governed
  memory but cannot curate.
- SDK helpers: `sdk/typescript` and `sdk/python`; F9 readiness helpers are
  transport-neutral while F8 still owns complete generated clients.
- Governance: `/governance/sign-in` for authenticated humans only.
- Evaluation: `mix cartulary.eval.smoke --profile balanced --account eval-poc`.
- Release evaluation and guardrails: `docs/eval/README.md`.
- Semantic versioning and changelog policy: `versioning.md`.
- Release procedure and required CI checks: `release-checklist.md`.
- Logical moves: `docs/operations/portability.md`.
- Disaster recovery: `docs/operations/backup-restore.md`.
