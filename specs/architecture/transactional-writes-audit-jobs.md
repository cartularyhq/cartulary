<!-- SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0 -->

# Transactional Writes, Audit, And Jobs

Status: implemented

Transactional writes, audit, and jobs make an accepted raw observation, its
immutable audit event, its durable processing identity, and its AshOban job
one PostgreSQL transaction. They implement `AD-DATA-8`, `AD-PIPE-1`,
`AD-PIPE-3`, `AD-PIPE-4`, `AD-SEAM-4.2`, `AD-SEAM-4.3`, `FR-KN-9`,
`FR-FORM-8`, `FR-GOV-17`, `FR-GOV-20`, and `NFR-8` without changing the frozen
`poc-0` HTTP surface. `poc-0` is a historical version tag for that frozen
contract and no longer names a roadmap phase.

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

## A background job declares its own Account

A job has no request behind it, so nothing upstream of it has installed the
transaction-local Account settings that the row-level-security policies on
every tenant table compare against. Since `AD-DATA-1` isolation became
enforced at the database (the application connects as a role that cannot
bypass row-level security), an undeclared connection sees no `pipeline_runs`
row and may write none.

That matters because AshOban touches the run row twice outside anything
Cartulary controls: the worker reads the row back to confirm its trigger still
applies, and the error handler writes the failed attempt. Undeclared, the read
returns nothing and the runner cancels the job as `trigger_no_longer_applies`,
and the write matches nothing and surfaces as a stale record — both of which
look identical to "this work was already handled" while the work is in fact
outstanding.

The declaration therefore belongs to the actions themselves, not to their
callers:

- `PipelineRun.for_trigger` is a transactional read used by every trigger's
  `worker_read_action`. `Cartulary.Pipeline.Preparations.DeclareAccount`
  installs the query's tenant before the statement runs.
- `PipelineRun.execute` and `PipelineRun.mark_failed` carry
  `Cartulary.Pipeline.Changes.DeclareAccount`, which installs the updated row's
  own Account inside the action's transaction.
- `Cartulary.DataLayer.declare_account!/1` performs the installation and never
  overwrites a declaration already in force, so an enclosing Account-scoped
  transaction still wins and the change can never switch or widen tenancy.

`execute` is transactional for that write only. Its Ash change runs the lane's
Reactor in a `before_transaction` hook, which keeps the long-running work
outside the transaction exactly as before while the short status write gains
the declaration it needs.

## No external call inside an Account transaction

A transaction owns a pooled PostgreSQL connection for its whole duration, and
DBConnection closes a connection whose checkout exceeds its ownership timeout —
15 000 ms by default, which nothing overrides for `Cartulary.Repo`. An
extraction can spend far longer than that in a model provider: the structured
generator allows two repair attempts beyond the first call, and
`CARTULARY_MODEL_RECEIVE_TIMEOUT_MS` defaults to 120 000 ms per call. A
transaction spanning those calls is therefore not slow but wrong — the
connection is closed mid-transaction and the write recording an
already-completed, already-billed call is discarded, so the job retries and the
Account pays twice.

Work that mixes durable writes with an external call is therefore split into
three phases: a short transaction that reads everything the call needs, the
call itself holding no connection, and a second short transaction that commits
what the call produced. `Cartulary.Memory.extract_message/2`,
`Cartulary.Memory.extract_message_for_account/2`, and
`Cartulary.Documents.Service.process_version_for_account/2` all have this
shape; the document lane's external phase also covers the blob fetch, the
parse, and the embedding call.

Two database touches happen *during* a provider call and cannot be lifted out
of it: resolving the Account's stored `ModelRoleConfig`, and appending the
`UsageEvent` for the call. Both scope themselves through
`Cartulary.DataLayer.in_account_transaction/2`, which installs the Account
setting the row-level-security policies read without resolving an Account row
or building an actor. Nesting is deliberate: it always opens a transaction
rather than branching on `Repo.in_transaction?/0`, because under the SQL
sandbox every test already runs inside one, so a branch would make the
production path the one no test exercises.

A consequence worth stating: a usage record commits independently of whatever
the caller does next. A caller whose own write fails afterwards no longer takes
the ledger row down with it, which is correct — the call happened and was
billed regardless.

Ordering, idempotency, and locking are unchanged by the split. The duplicate
check and the transaction-scoped advisory lock already sat after the model
call, so both stay together in the write phase and still serialize concurrent
writers. Neither the observation nor the version is stamped as processed until
its write phase commits, so an interrupted extraction is found again by the
reconciler rather than silently lost.

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

This capability owns durable execution, retry, uniqueness, and continuation
seams. Gate A/B governance owns the real gate/revalidation/expiry semantics;
the model layer and structured extraction own document extraction and
model-backed reasoning; documents, connectors, and sync own connector
behavior; retrieval, entity resolution, and context own projections; and
portability, packaging, and operations own the logical import/export
implementation. Until each of those capabilities lands, its lane here
completes a typed durable continuation without inventing the later domain
behavior.

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

`Cartulary.Pipeline.Lock` is the transactional-writes infrastructure exception
that uses a parameterized PostgreSQL advisory-lock query. It performs no
durable write; all durable state still goes through Ash actions.

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
actions emit the applicable events, while Gate A/B erasure and governance
actions will use the same append API.

## Evidence

`test/cartulary/f2_transactional_writes_audit_jobs_test.exs` proves:

- commit coupling for raw observation, audit, pipeline run, and Oban job;
- rollback coupling after audit and enqueue;
- actual AshOban execution through the ingest Reactor;
- replay-safe knowledge/provenance/lifecycle behavior;
- raw persistence while a configured model provider is unavailable;
- deterministic audit-chain recomputation with no raw content in metadata;
- trigger execution and failure recording on a connection with no Account
  declared, which is the state every background job actually starts from; and
- registration of every transactional trigger, Reactor, category, and key
  family.

The frozen API baseline contract tests and the Ash domain backbone action/RLS
suite remain regression gates.
