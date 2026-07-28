<!-- SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0 -->

# Portability, Packaging, And Operations

Status: implemented on 2026-07-28.

Portability, packaging, and operations make the community core installable,
movable, observable, and recoverable without changing its 38-Resource durable
boundary. This work implements FR-PLAT-2, FR-PLAT-5, FR-PLAT-8 through
FR-PLAT-11, FR-PLAT-14, AD-CFG-2, AD-PORT-1 through AD-PORT-4, AD-OBS-1
through AD-OBS-7, NFR-7 through NFR-9, and ADR-0003. The ARCH prime directive
remains intact: pg0 and external Postgres are infrastructure adapters around
the same release, Repo, Ash actions, migrations, Oban queues, and product
behavior.

## Deployment boundary

`CARTULARY_DATABASE_MODE` is exactly `pg0` or `external`. Runtime validation
rejects an unsupported mode, a missing external `DATABASE_URL`, a conflicting
pg0 `DATABASE_URL`, an invalid port, a missing or non-executable pg0 binary, a
relative data/blob path, incomplete S3 configuration, and structurally invalid
model roles before the durable services start.

The no-container release stages pg0 v0.14.2, PostgreSQL 18.1.0, and pgvector
0.8.1 from the platform-specific upstream asset. `rel/pg0/checksums.txt`
contains the reviewed SHA-256 digest for every supported asset. The release
supervisor starts pg0 before `Cartulary.Repo`, runs migrations before serving,
detects a conflicting port, moves a dead `postmaster.pid` aside instead of
deleting it, attaches to a live data directory, and stops its named instance on
orderly shutdown. The Unix and Windows server launchers create a private,
persistent local data root and signing secret on first run.

The container image deliberately contains no pg0. `compose.yml` runs the same
release against stock `pgvector/pgvector:pg18-bookworm`, uses durable database
and blob volumes, and offers an `observability` profile for the OpenTelemetry
Collector, Jaeger, and Prometheus. Redis and a second worker runtime remain
absent.

## Logical portability

The archive schema is `cartulary-account-1`. A gzip tar contains:

- `manifest.json` with Account identity, embedder provenance, resource counts
  and checksums, blob checksums, audit head/count, and explicit exclusions;
- one streaming, keyset-paginated JSONL file for each of 33 portable durable
  Resources;
- checksum-addressed original document blobs.

Export runs in one Account-scoped database transaction. Import rejects unsafe
tar paths, unknown schemas/resources, checksum or count mismatches, blob hash
mismatches, and any branched, cyclic, disconnected, or content-tampered audit
chain before opening its write transaction. All durable restoration uses
private Ash actions under the system/pipeline actor, preserving ids, valid
times, belief times, lifecycle history, usage events, pipeline replay keys, and
content-safe audit hashes. Deferred self-links are restored only after their
rows exist.

Credentials, password hashes, secret values, vectors, document chunks,
projections, entities, entity mentions, extracted-text caches, and extraction
metadata are not portable. Import targets a fresh Account, stores verified
blobs through the configured blob adapter, commits resource restoration once,
then enqueues replay-keyed scope and document rebuild work. Independent
provenance and immutable document history remain intact.

## Operational surfaces

`GET /api/health` remains the frozen baseline liveness contract.
`GET /api/ready` adds the versioned `f10-1` operator contract (a historical
version tag, not a roadmap phase) and returns 200 only when the app,
database, Oban supervisor, queue query, and four model-role configurations are
healthy; failures return content-safe error classes with 503.

Every authenticated HTTP request emits an exact `UsageEvent`; ingest requests
are identified separately. Model usage continues to have one durable emission
point in `Cartulary.Model.Usage`. Rebuildable ETS counters provide inexpensive
daily admission checks, with dream-time throttled before user-facing ingest or
governed reads. Account administrators can inspect exact API, ingest, token,
role, and logical-storage totals plus operator-configured USD estimates at
`GET /api/v1/operations/costs`.

Production logs use a JSON formatter with an explicit metadata allowlist and
credential redaction. Queue depth and portability duration telemetry join the
existing HTTP, model, pipeline, governance, document, retrieval, and context
spans. Payloads, prompts, keys, document text, connector cursors, and knowledge
content remain excluded.

## Evidence

The focused contract is
`test/cartulary/f10_portability_packaging_operations_test.exs`. It covers
archive composition/exclusions, audit tamper rejection, readiness, exact edge
metering/cost visibility, and packaging invariants.

The implementation was also exercised with a real two-database round trip:
33 resource counts, six audit events and the final audit hash matched exactly;
the fresh target enqueued two scope rebuilds and carried no exported vectors.
The packaged release started a fresh pg0 instance, applied migrations, became
ready, and stopped the managed database. The external lane uses the same
migration and test contracts against the stock Postgres image from
`compose.yml`. The production container built with the pinned Rust builder,
started as UID 10001 without Rust or pg0 in its runtime layer, and returned
`f10-1` readiness against that stock Postgres service.

Operator procedures live in:

- `docs/operations/README.md`
- `docs/operations/portability.md`
- `docs/operations/backup-restore.md`
