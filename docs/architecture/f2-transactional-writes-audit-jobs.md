<!-- SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0 -->

# F2 Transactional Writes, Audit, And Jobs

Status: implemented

F2 makes an accepted raw observation, its immutable audit event, its durable
processing identity, and its AshOban job one PostgreSQL transaction. It
implements `AD-DATA-8`, `AD-PIPE-1`, `AD-PIPE-3`, `AD-PIPE-4`,
`AD-SEAM-4.2`, `AD-SEAM-4.3`, `FR-KN-9`, `FR-FORM-8`, `FR-GOV-17`,
`FR-GOV-20`, and `NFR-8` without changing the frozen `poc-0` HTTP surface.

## Transaction boundary

`Cartulary.Observations.Message.create` and
`Cartulary.Observations.DocumentVersion.create` use Ash changes that:

1. compute a SHA-256 content hash without copying content into operational
   metadata;
2. append an Account-local audit event;
3. create or reuse a unique `Cartulary.Operations.PipelineRun`; and
4. insert its AshOban trigger job.

All four writes use the caller's existing `Cartulary.Repo` transaction. An
error after the enqueue rolls all of them back. Message ingestion always takes
this asynchronous path. The synchronous extraction response retained by
`poc-0` runs only after that transaction commits and is safe to replay when the
queued job later executes.

`PipelineRun` is durable processing state, not a second queue. Its unique
`{account_id, idempotency_key}` identity lets the reconciler and event sources
request the same work repeatedly. Oban remains the single execution engine in
both deployment modes.

## Job and Reactor map

| Lane | Queue | Orchestration |
| --- | --- | --- |
| message/document extraction | `ingest` | `IngestExtraction` Reactor |
| dream-time, entity resolution, projection refresh | `dream` / `projection` | `DreamTimeReasoning` Reactor |
| revalidation and expiry | `lifecycle` | maintenance Reactor continuation |
| validation and answer correlation | `governance` | dedicated continuation Reactors |
| connector sync | `connector` | maintenance Reactor continuation |
| import-derived-cache rebuild | `portability` | maintenance Reactor continuation |
| unprocessed-record reconciliation | `reconciler` | Account-scoped reconciler |

F2 owns durable execution, retry, uniqueness, and continuation seams. F4 owns
the real gate/revalidation/expiry semantics, F5 owns document extraction and
model-backed reasoning, F6 owns connector behavior, F9 owns projections, and
F12 owns the logical import/export implementation. Until those phases land,
their F2 lanes complete a typed durable continuation without inventing the
later domain behavior.

## Idempotency and reconciliation

`Cartulary.Pipeline.Idempotency` defines deterministic keys for:

- message id plus content hash;
- document-version id plus content hash;
- scope plus dream-time watermark;
- scope plus projection watermark;
- scope plus entity-resolution watermark;
- import id plus manifest hash;
- validation decision plus knowledge id; and
- validation question plus session id.

Knowledge merges take a transaction-scoped, Account/key advisory lock before
the exact-statement check. Replay reuses the knowledge item, attribution, and
provenance rows and does not append a second creation lifecycle event. The
Account-scoped reconciler scans raw messages without
`extraction_completed_at` and re-enqueues the deterministic extraction key.

`Cartulary.Pipeline.Lock` is the F2 infrastructure exception that uses a
parameterized PostgreSQL advisory-lock query. It performs no durable write;
all durable state still goes through Ash actions.

## Audit chain

`Cartulary.Governance.AuditEvent` remains append-only and now carries:

- event category and action;
- resource id/type;
- optional content hash, never raw content;
- content-safe metadata;
- the previous Account event hash; and
- the deterministic SHA-256 event hash.

An Account-scoped transaction advisory lock serializes only that Account's
chain tip. Different Accounts do not block one another. The audit action reads
the prior tip and inserts the new event in the same transaction as the domain
change. Lifecycle, gate, attribution, observation, deletion, configuration,
and governance categories are reserved; current message/knowledge and policy
actions emit the applicable events, while F4 erasure and governance actions
will use the same append API.

## Evidence

`test/cartulary/f2_transactional_writes_audit_jobs_test.exs` proves:

- commit coupling for raw observation, audit, pipeline run, and Oban job;
- rollback coupling after audit and enqueue;
- actual AshOban execution through the ingest Reactor;
- replay-safe knowledge/provenance/lifecycle behavior;
- raw persistence while a configured model provider is unavailable;
- deterministic audit-chain recomputation with no raw content in metadata; and
- registration of every F2 trigger, Reactor, category, and key family.

F0 contract tests and the F1 action/RLS suite remain regression gates.
