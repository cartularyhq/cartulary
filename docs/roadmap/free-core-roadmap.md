<!-- SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0 -->

# Free Core Architecture And Roadmap

Status: active roadmap; F0-F1 complete
Date: 2026-07-27

This roadmap turns the working local POC into the complete free self-host core:
one Account, one Mix release, one BEAM node by default, Postgres through pg0 or
an external connection string, the full governed memory engine, local/offline
model options, MCP, HTTP, gateway, generated SDKs, basic RBAC, export/import,
and release-grade evaluation.

It is subordinate to the blueprint specs and ADRs. The stable anchors remain in:

- `specs/memory-system-functional-requirements.md`
- `specs/memory-system-architecture-and-nfr.md`
- `specs/memory-system-product-blueprint.md`
- `docs/adr/0003-embedded-postgres-pg0.md`
- `docs/adr/0004-multi-strategy-retrieval.md`
- `docs/adr/0005-peer-inline-validation-over-mcp.md`
- `docs/adr/0006-entity-resolution.md`
- `docs/poc-local-proof.md`

## Scope

The free core includes everything required to run Cartulary as a complete,
single-Account, self-hosted memory system:

- Full memory topology: Account, Peers, Scopes, scope tree, scope relations,
  sessions, raw observations, documents, knowledge, provenance, lifecycle,
  attributions, relations, projections, entities, and skill requirement cards
  (`FR-TOP-*`, `FR-KN-*`, `FR-SK-*`).
- The governed write path: agents submit raw observations only; the pipeline is
  the sole writer of knowledge; Gate A and Gate B decide retention, attribution,
  sensitivity, consent, and blast radius (`FR-FORM-*`, `FR-GOV-*`,
  `FR-API-12`).
- The read path: `get_context`, `ask`, `search`, `query_knowledge`, and
  `check_readiness`, with scope-anchored reads, downward inheritance,
  point-in-time filters, provenance filters, grounded answers, and abstention
  (`FR-API-*`).
- Multi-strategy retrieval: semantic, lexical, temporal, salience-recency,
  entity-match, relation expansion, reciprocal-rank fusion, optional rerank,
  named versioned profiles, deadlines, and strategy self-reporting
  (`FR-API-25` to `FR-API-29`, `AD-SEAM-3`).
- Single-node packaging: one Mix release, embedded pinned pg0 by default,
  external Postgres as a connection-string change, stock Postgres in containers,
  no Redis, no second engine runtime (`FR-PLAT-2`, `FR-PLAT-4`,
  `FR-PLAT-5`, `AD-CFG-2`).
- Provider-neutral models: four account-level model roles over ReqLLM,
  OpenAI-compatible and self-hosted endpoints, Ortex/ONNX default embeddings,
  pinned embedding versions, and usage metering by role (`FR-API-17` to
  `FR-API-20`, `AD-MODEL-*`, `FR-PLAT-8`).
- Free integration surfaces: AshJsonApi/OpenAPI, MCP over `ash_ai`, the
  OpenAI/Anthropic-compatible gateway proxy, Phoenix LiveView governance, and
  generated TypeScript/Python SDKs (`FR-API-11`, `FR-API-14` to `FR-API-22`,
  `AD-API-*`).
- Basic governance and transparency: validation queue, peer self-view, contest
  and redact, revalidation, immutable audit, history/diff view, local auth,
  API keys, magic links, per-scope roles, and RLS keyed on Account
  (`FR-GOV-*`, `FR-PLAT-6`, `AD-SEC-*`).
- Free portability: logical account export/import, audit hash-chain continuity,
  rebuild of derived caches on import, and documented backup/restore paths
  (`FR-PLAT-11`, `FR-PLAT-14`, `AD-PORT-*`).

The free core excludes enterprise-only scale and compliance features:

- Multiple Accounts, queue mode, clustered nodes, SSO/SAML/SCIM, schema/db per
  Account, granular enterprise RBAC, CMK, audit SIEM streaming, advanced
  retention controls, managed SaaS operations, and support/compliance packaging
  (`FR-PLAT-3`, `FR-PLAT-7`, `FR-PLAT-13`, `FR-PLAT-15`).
- The deferred graph/triple layer, AshGraphql, live streaming migration,
  carry-vectors import fast path, per-scope model-role overrides, far-scale
  sharding, and peer merge/aliasing unless a later blueprint change promotes
  them into scope.

## Architecture Plan

### Prime Structure

Cartulary remains one Elixir/Ash/Phoenix/Oban codebase and one Mix release
(`AINV-1`, `AD-LANG-1`, `AD-LANG-2`). The POC's working behavior is preserved
while the internals move from one SQL-heavy service into Ash-shaped modules:

```text
Surfaces
  Phoenix HTTP / AshJsonApi / MCP / gateway proxy / LiveView governance
    call
Ash Actions
  one typed operation set for ingest, reads, governance, skills, export/import
    coordinate
Domains
  Accounts, Topology, Observations, Knowledge, Governance, Pipeline,
  Retrieval, Context, Skills, Documents, Models, Operations, Portability
    use
Behaviours and Strategies
  Retrieval.Strategy, Fusion, Reranker, GatePolicy, Chunker,
  ModelTiering, Embedder, Generator, BlobStore, SecretStore
    run over
Infrastructure
  AshPostgres + pgvector + PG-FTS, Oban through AshOban, ReqLLM,
  local FS or S3-compatible blob, runtime config, telemetry
```

The dependency rule is simple: surfaces call Ash actions; actions coordinate
domain modules; domain modules use behaviours and Ash data layers; only
infrastructure modules know concrete clients such as `Repo`, ReqLLM providers,
pg0, or blob adapters. Core never imports enterprise modules.

### Domain Decomposition

The target free core is a modular monolith. Each module boundary is a future
extraction point, not a separate service.

| Domain | Owns | Main anchors |
| --- | --- | --- |
| `Cartulary.Accounts` | Account, local identities, API keys, peer identity links, single-Account enforcement | `FR-TOP-1`, `FR-TOP-2`, `AINV-6`, `AD-SEC-*` |
| `Cartulary.Topology` | Scopes, materialized paths, scope relations, role grants, inheritance resolution | `FR-TOP-3` to `FR-TOP-11`, `FR-GOV-18`, `FR-GOV-19`, `AD-DATA-4` |
| `Cartulary.Observations` | Sessions, session scopes, participants, raw messages, documents, document versions | `FR-FORM-1` to `FR-FORM-13` |
| `Cartulary.Knowledge` | Knowledge items, attributions, provenance, lifecycle ledger, relations, current-state materialization | `FR-KN-*`, `FR-FORM-19` to `FR-FORM-23`, `AD-DATA-1` to `AD-DATA-3` |
| `Cartulary.Governance` | Gate A/B policy, validation queue, consent, peer self-view, contest/redact, audit, history/diff | `FR-GOV-*`, `AD-GOV-*`, `AD-DATA-8` |
| `Cartulary.Pipeline` | Ingest-time extraction, dream-time reasoning, revalidation/expiry sweeps, connector sync orchestration | `FR-FORM-14` to `FR-FORM-18`, `AD-PIPE-*` |
| `Cartulary.Retrieval` | Strategy behaviour, seed and expansion strategies, RRF fusion, rerank, profile versions, deadlines | `FR-API-25` to `FR-API-29`, `AD-SEAM-3` |
| `Cartulary.Context` | Reasoning-free `get_context`, projection reads, context budget assembly, salience-ranked knowledge slices | `FR-API-4`, `FR-API-5`, `FR-API-10`, `NFR-2` |
| `Cartulary.Query` | `ask`, `search`, `query_knowledge`, point-in-time and provenance filters, grounding and abstention | `FR-API-1` to `FR-API-8`, `FR-API-23`, `FR-API-24`, `FR-API-26` |
| `Cartulary.Skills` | Skill requirement cards, inherited requirements, readiness checks, gap reports, elicitation hooks | `FR-SK-*`, `FR-API-9` |
| `Cartulary.Documents` | Native extraction, chunking, document embeddings, content-hash sync hooks | `FR-FORM-9` to `FR-FORM-12` |
| `Cartulary.Model` | ReqLLM provider layer, model roles, structured generation, embedding role, usage emission | `FR-API-17` to `FR-API-20`, `AD-MODEL-*` |
| `Cartulary.Operations` | Health, readiness, telemetry, usage ledger, budget counters, local observability | `FR-PLAT-8` to `FR-PLAT-10`, `AD-OBS-*` |
| `Cartulary.Portability` | Logical export/import, import validation, cache rebuild scheduling, backup/restore runbooks | `FR-PLAT-11`, `FR-PLAT-14`, `AD-PORT-*` |
| `Cartulary.Release` | Runtime config validation, pg0 supervision, migration on boot, packaging modes | `FR-PLAT-2`, `FR-PLAT-4`, `FR-PLAT-5`, `AD-CFG-2` |

### Abstraction Layers

Use Ash as the primary ports-and-adapters mechanism:

- Ash Resources are the durable type system and policy boundary.
- Ash Actions are the operation boundary. All public operations, background
  steps, and governance decisions should resolve to actions instead of direct
  SQL helpers.
- Ash policies and Postgres RLS jointly enforce Account isolation. The edge
  derives Account from identity and sets Ash actor/tenant; request bodies never
  select an Account (`AINV-6`).
- AshOban owns background enqueue inside the same transaction as the state
  change that requires it (`AD-SEAM-4`, `AD-PIPE-1`).
- Ash.Reactor owns multi-step pipeline orchestration where steps need retries,
  compensation, idempotency, or human-signal continuation.
- Elixir behaviours own product strategy variability: retrieval strategies,
  gates, chunking, model tiering, embeddings, generators, rerankers, blob store,
  and secrets.
- Runtime config selects infrastructure location and enabled modules; DB-stored
  policy config selects behavior at Account/scope grain; per-query config can
  select a named retrieval profile only (`AD-CFG-1`).

### Durable Stores And Derived Caches

The system of record is:

- raw sessions, messages, documents, and document versions;
- validated knowledge statements with attributions, provenance, lifecycle
  ledger, relations, sensitivity, confidence, valid-time, salience, and
  system-derived belief-time;
- immutable audit log entries and usage/metering events;
- policy/configuration records such as roles, model roles, budgets, gate
  matrix, channel allowlist, and skill cards.

Derived and rebuildable data is:

- peer profiles, scope cards, session summaries, context projection fragments;
- entity and entity-mention caches;
- document chunks when they can be regenerated from durable document versions;
- vector and lexical indices;
- ETS and `persistent_term` hot caches.

Every roadmap item that writes a derived cache must include a rebuild path,
dirty marking, and erasure recomputation evidence (`AINV-5`, `FR-GOV-15`,
`FR-GOV-16`, `FR-KN-22`).

### Public Operation Set

The complete free core exposes these operations once as Ash actions and adapts
them to each surface:

- Agent-facing writes: `ingest`, `add_message`, document ingest, connector sync
  submit. These persist raw observations only.
- Reads: `get_context`, `ask`, `search`, `query_knowledge`, `check_readiness`.
- Peer inline validation over MCP: `resolve_validation` and
  `set_ask_preference`, restricted to the calling peer's own pending questions
  and clamp-only preference changes.
- Human governance: validation queue actions, scope proposal confirmation,
  consent, peer self-view, contest/redact, history/diff, export/import, local
  admin policy changes.
- Internal/eval probes behind explicit config: run dream-time now, inspect
  queue state, inspect lifecycle intervals, disable/fix retrieval deadlines,
  and run benchmark/report tasks.

### POC Migration Posture

The POC remains a working checkpoint, not a permanent architecture. Migration
uses a strangler pattern:

1. Preserve current HTTP behavior and eval tasks while adding Ash actions
   behind the same user-facing contract.
2. Move one durable write path at a time from `Cartulary.Memory` direct SQL into
   Ash resources/actions, with tests proving unchanged POC behavior plus the
   new invariant.
3. Keep direct SQL only for temporary, named transition helpers. Remove each
   helper in the same phase that replaces its behavior.
4. Promote POC fixtures into deterministic regression tests before replacing the
   subsystem they exercise.
5. Add the doc or ADR update in the same PR as any behavior change that changes
   semantics, risk, or an architectural decision.

The migration is complete only when no public path depends on
`Cartulary.Memory` as a SQL service module and all writes flow through Ash
actions, policies, transactions, audit, and AshOban.

## Roadmap

Each phase should be executed as focused L3 tasks: one issue, one branch, one
PR. A phase may require many PRs. Do not batch phase-sized work.

Checkboxes are evidence markers, not estimates. Mark a deliverable or
acceptance item complete only when its implementation, regression evidence, and
closest durable documentation are committed together. Reopen the checkbox if
that evidence is removed or no longer passes.

### F0: Freeze The POC Contract

Goal: make the current working behavior a stable regression baseline before
moving internals.

Deliverables:

- [x] HTTP endpoint tests for health, ingest, search, ask, context, and knowledge.
- [x] Database tests for POC account header behavior, scope inheritance, message
  persistence, knowledge insertion, lifecycle event insertion, and deterministic
  extractor fallback.
- [x] Eval fixture baselines committed for the tiny Cartulary, LoCoMo, LongMemEval,
  and BEAM fixtures already described in `docs/poc-local-proof.md`.
- [x] A short transition note in `Cartulary.Memory` naming it as a temporary facade
  until Ash actions replace it.

Acceptance:

- [x] Existing POC commands still pass.
- [x] Tests fail if an agent can write knowledge directly or if request body data
  overrides the caller-derived Account.

F0 evidence lives in `test/cartulary/poc_contract_test.exs`,
`test/cartulary_web/controllers/memory_controller_test.exs`,
`test/cartulary/eval/fixture_contract_test.exs`, and
`test/fixtures/eval/poc-contract-baseline.json`. The baseline is named `poc-0`;
future phases may replace its internals but must preserve or intentionally
version its public behavior.

### F1: Ash Domain Backbone

Goal: make Ash Resources and Actions the authoritative domain boundary.

Deliverables:

- [x] Resource model for Account, Peer, external identity, Scope, ScopeRelation,
  RoleGrant, Session, SessionScope, SessionParticipant, Message, Document,
  DocumentVersion, KnowledgeItem, Attribution, Provenance, KnowledgeRelation,
  LifecycleEvent, AuditEvent, UsageEvent, PolicyConfig, ModelRoleConfig,
  RetrievalProfile, SkillRequirementCard, Projection, Entity, and EntityMention.
- [x] Ash Domains matching the decomposition above.
- [x] Generated migrations plus custom Postgres DDL for pgcrypto, pgvector, PG-FTS,
  indexes, and RLS.
- [x] Ash actions for create/read/update operations where updates are legal, with
  create-only content and append-only lifecycle/audit events.
- [x] Ash policies for Account wall, scope read access, and governance action
  separation.

Acceptance:

- [x] `Cartulary.Memory` can call Ash actions for accounts, scopes, peers,
  sessions, messages, and knowledge.
- [x] Direct Repo access is confined to infrastructure/data-layer modules and
  custom query helpers that have an explicit transition ticket.
- [x] Cross-account isolation has deterministic tests at action and DB policy
  levels.

F1 evidence lives in the domain modules under `lib/cartulary/`,
`priv/resource_snapshots/`,
`priv/repo/migrations/20260727142300_f1_ash_domain_backbone.exs`, and
`test/cartulary/f1_ash_domain_backbone_test.exs`. The implementation boundary
and F2/F3/F7 transition tickets are documented in
`docs/architecture/f1-ash-domain-backbone.md`. The F0 `poc-0` contract remains
unchanged.

### F2: Transactional Writes, Audit, And Jobs

Goal: every state transition, audit entry, and background enqueue that belongs
to one operation commits together.

Deliverables:

- [x] AshOban integration for extraction, dream-time, revalidation, expiry,
  projection refresh, connector sync, export/import cache rebuild, and
  reconciler jobs.
- [x] Ash.Reactor flows for ingest-time extraction, dream-time reasoning, validation
  continuation, and answer-correlation continuation.
- [x] Idempotency keys for message extraction, document extraction, dream-time by
  scope/watermark, projection refresh, entity resolution, and import rebuilds.
- [x] Hash-chained per-Account audit events for lifecycle, gate, attribution,
  deletion, configuration, and governance decisions.
- [x] Reconciler jobs for durable records that were committed but not processed.

Acceptance:

- [x] Tests prove rollback removes the raw write, audit entry, and queued job
  together.
- [x] Re-running any pipeline job is safe and produces no duplicate knowledge beyond
  allowed provenance merges.
- [x] Ingest persists raw observations even when model providers are unavailable.

F2 evidence lives in `Cartulary.Operations.PipelineRun`, the AshOban triggers
and Ash.Reactor flows under `lib/cartulary/pipeline/`,
`priv/repo/migrations/20260727150730_f2_transactional_writes_audit_jobs.exs`,
`priv/repo/migrations/20260727150740_update_oban_v14.exs`, and
`test/cartulary/f2_transactional_writes_audit_jobs_test.exs`. The transaction,
idempotency, audit-chain, reconciliation, and later-phase continuation
boundaries are documented in
`docs/architecture/f2-transactional-writes-audit-jobs.md`. The F0 `poc-0`
surface remains compatible: synchronous extraction is an after-commit
compatibility path while every ingest also commits its durable asynchronous
work.

### F3: Identity, Tenancy, And Basic RBAC

Goal: replace local header-based identity with free-core identity-derived
Account and scope authorization.

Deliverables:

- [ ] AshAuthentication local identity: password or magic-link for humans, API-key
  strategy for agents.
- [ ] Peer and external identity linking with assurance levels.
- [ ] Single-Account enforcement for the free release with an explicit migration
  path for later enterprise multi-Account enablement.
- [ ] Role grants for account-admin, curator, member, reader with inheritance down
  the scope tree.
- [ ] Postgres RLS keyed on Account everywhere, even though free mode is limited to
  one Account.
- [ ] Scope read checks for containment path and cross-linked scopes.

Acceptance:

- [ ] Account is derived from authenticated identity on every surface.
- [ ] Unknown or foreign IDs return non-leaking failures where required, especially
  peer inline validation IDs.
- [ ] Property tests cover account wall and scope inheritance.

### F4: Real Gate A/B Governance

Goal: replace the POC auto-activation shortcut with governed lifecycle actions.

Deliverables:

- [ ] Gate matrix resource for confidence x target level x sensitivity.
- [ ] Gate A decision path: keep, reject, defer, provisional peer-level visibility.
- [ ] Gate B decision path: attribution level, blast-radius checks, personal
  consent, curator routing, and held scope-level proposals.
- [ ] Validation queue resource and LiveView UI for approve, edit, reject, merge,
  defer, bulk actions, and conflict bundles.
- [ ] Peer self-view, contest/redact, right-to-be-forgotten, proportionate erasure,
  strict erasure, and affected projection/entity recomputation.
- [ ] Revalidation timers, confidence decay, pending aging, escalation, and
  auto-reject policy.
- [ ] MCP inline peer validation attachment and answer resolution following
  `FR-API-30`, `FR-API-31`, and `FR-GOV-22`.

Acceptance:

- [ ] Agents cannot reach curator governance actions through MCP or machine API
  credentials.
- [ ] Scope-level pending knowledge is not surfaced before approval.
- [ ] Upward personal attribution cannot become active without subject consent.
- [ ] Every gate and lifecycle change is visible in history/diff and audit.

### F5: Model Layer And Structured Extraction

Goal: make models provider-neutral, testable, metered, and suitable for local
offline use.

Deliverables:

- [ ] ReqLLM-backed provider layer with four roles: embedder, ingest extractor,
  dream-time reasoner, dialectic agent.
- [ ] `AshAi.EmbeddingModel` embedder implementation for Ortex/ONNX by default,
  plus OpenAI-compatible/API embedding configuration.
- [ ] Structured generator behavior for extractor and reasoner using Ash resource
  schemas, bounded validate-and-repair, and provider cassettes for deterministic
  tests.
- [ ] Model provenance fields: provider, model, version, prompt version, pipeline
  version, embedding model/version.
- [ ] Usage emission in one place for token, embedding, latency, role, account, and
  scope.
- [ ] Explicit model outage handling: raw ingest persists; extraction/dream-time
  jobs retry; context reads survive without a model.

Acceptance:

- [ ] Tests can inject a fake provider for extraction, dream-time, embeddings,
  rerank, and dialectic answers.
- [ ] Embedder changes require a versioned re-embed path and cannot silently reuse
  incompatible vectors.
- [ ] The deterministic fallback remains available only as a test/local fallback,
  not as the architectural extractor.

### F6: Documents, Connectors, And Sync

Goal: support document memory as a first-class free-core path.

Deliverables:

- [ ] Document and DocumentVersion resources with content hashes, source metadata,
  blob refs, and scope visibility.
- [ ] Extractous/ExtractousEx and MDEx ingestion for PDF, Office, email, markdown,
  and text where supported by the chosen libraries.
- [ ] `bitcrowd/rag` chunking path for document chunks and retrieval metrics.
- [ ] Dual ingest: chunk + embed for retrieval, and extract knowledge through the
  same Gate A/B pipeline.
- [ ] Connector behavior with schedule, cursor, content-hash change detection,
  deletion/tombstone handling, and re-extract/supersede behavior.
- [ ] Local filesystem blob store for free core and an S3-compatible adapter
  retained as an infrastructure port.

Acceptance:

- [ ] A changed synced document supersedes knowledge derived from the prior version
  without overwriting history.
- [ ] Erasure and export/import handle blobs, document metadata, and derived chunks
  correctly.

### F7: Retrieval, Entity Resolution, And Context

Goal: replace inline SQL retrieval with the complete profile-based retrieval
and reasoning-free context assembly.

Deliverables:

- [ ] `Cartulary.Retrieval.Strategy` behavior with independent contracts.
- [ ] Seed strategies: Semantic, Lexical, Temporal, SalienceRecency, EntityMatch.
- [ ] Expansion strategy: RelationExpand over knowledge relations, scope relations,
  and shared-entity edges.
- [ ] RRF fusion, optional rerank over fused head, profile versioning, profile
  inheritance, deadlines, dropped-strategy reporting, and internal/eval raw
  strategy overrides.
- [ ] Knowledge and document embedding columns, pgvector indexes, PG-FTS indexes,
  backfill/rebuild jobs, and tiny-corpus `Nx` baseline for tests/eval.
- [ ] Entity and EntityMention derived caches, dream-time resolution cascade, import
  rebuild, erasure recomputation, and no-public-entity-surface tests.
- [ ] Incremental projections: peer profile, scope card, session summary, dirty
  marking, delta updates, bounded full compaction, ETS/cache invalidation.
- [ ] `get_context` budget assembly from projections plus salience-ranked knowledge
  with no LLM call except the allowed `:fast` fallback on cache miss.

Acceptance:

- [ ] `search` defaults to `:balanced`; `ask` defaults to `:thorough`;
  `get_context` remains reasoning-free.
- [ ] Retrieval responses identify contributed and dropped strategies.
- [ ] Public surfaces never expose Entity or EntityMention rows, names, or aliases.
- [ ] Scope and Account filters are applied before candidate material leaves
  retrieval internals.

### F8: Grounded Ask, API Surfaces, Gateway, And SDKs

Goal: expose one complete operation set through all free-core integration
surfaces.

Deliverables:

- [ ] AshJsonApi endpoints and generated OpenAPI for ingest, reads, governance
  human actions, admin policy actions, export/import, and internal probes where
  explicitly enabled.
- [ ] `ash_ai` MCP tools for reads, ingest/add_message, peer validation resolution,
  and clamp-only ask preferences.
- [ ] Phoenix gateway proxy for OpenAI-compatible and Anthropic-compatible capture
  plus context injection.
- [ ] Generated TypeScript and Python SDKs with primitives, context injection,
  auto-forwarding, and skill-readiness helper.
- [ ] Grounded `ask` dialectic loop with citations, retrieved-id verification,
  stale/unknown handling, cross-strategy disagreement input, and abstention.
- [ ] Versioning rules for API path, OpenAPI schemas, MCP tool schemas, retrieval
  profiles, prompt versions, and SDK packages.

Acceptance:

- [ ] One action definition drives all transports.
- [ ] Agent credentials cannot call human governance actions through any route.
- [ ] `ask` cannot cite knowledge that was not retrieved in-loop and cannot invent
  an answer when the relevant knowledge is absent or stale.

### F9: Skill Readiness And Procedural Memory

Goal: ship the skill knowledge layer that makes memory operational before an
agent acts.

Deliverables:

- [ ] SkillRequirementCard authored resource with inherited scope overrides.
- [ ] Selector language over knowledge metadata, freshness, subject, source policy,
  and required/preferred levels.
- [ ] `check_readiness(skill, peer, scope)` action and API/MCP exposure.
- [ ] Gap report result schema, blocker/warning distinction, and SDK helper for
  elicitation.
- [ ] Revalidation integration so stale knowledge cannot satisfy requirements.
- [ ] Governance UI for authoring and reviewing skill cards.

Acceptance:

- [ ] Required gaps block the helper path.
- [ ] Preferred gaps warn without blocking.
- [ ] Expired or `needs_revalidation` knowledge does not satisfy readiness.

### F10: Portability, Packaging, And Operations

Goal: make the free core installable, movable, observable, and recoverable.

Deliverables:

- [ ] No-container Mix release with pinned pg0 binary, release-supervised lifecycle,
  first-run migration, stale lock handling, port conflict handling, data
  directory health checks, and external Postgres escape hatch.
- [ ] Container image and compose file for single-node free core using stock
  Postgres, plus optional local observability profile.
- [ ] Runtime config validation and clear boot errors for missing or conflicting
  settings.
- [ ] Logical account export/import with manifest, JSONL resources, blobs, audit
  hash-chain verification, derived cache exclusions, and rebuild jobs.
- [ ] Physical backup/restore runbook for pg0 directory, external Postgres, and
  blob storage.
- [ ] Health/readiness endpoints for app, DB, Oban, queues, and model role
  configuration.
- [ ] OpenTelemetry emission, redacted structured logging, exact usage/metering
  ledger, budget counters, and self-host cost visibility.
- [ ] Documentation for install, upgrade, backup/restore, export/import, model
  config, local embeddings, gateway, MCP, SDK, governance, and eval.

Acceptance:

- [ ] A new user can start a fresh free-core instance with one command on a
  supported platform after download.
- [ ] Export from one instance and import into a fresh instance preserves durable
  data, verifies audit continuity, and rebuilds derived caches.
- [ ] pg0-backed and external-Postgres paths have parity evidence.

### F11: Evaluation, CI, And Release Readiness

Goal: make quality claims reproducible and release gates real.

Deliverables:

- [ ] Deterministic PR gate: format, compile warnings-as-errors, tests, Credo,
  Dialyzer, Sobelow, data-layer contracts, strategy contracts, OpenAPI/MCP/SDK
  contracts, account isolation properties, consent/promotion scenarios, and
  no-public-entity-surface tests.
- [ ] Provider cassette layer for realistic deterministic model tests.
- [ ] Release/nightly eval: LoCoMo, LongMemEval, ConvoMem, BEAM degradation curve,
  Cartulary product evaluations, groundedness, context relevance, answer
  relevance, token efficiency, latency, abstention, and strategy-ablation
  matrices.
- [ ] Stage 0 benchmark baselines before retrieval strategy changes, held-out
  tuning discipline, profile-version citations, and deadline setting in every
  published number.
- [ ] CI lanes for pg0 and external Postgres where available.
- [ ] Release checklist and changelog discipline tied to blueprint anchors.

Acceptance:

- [ ] A release cannot be cut with failing deterministic guardrails.
- [ ] Public benchmark or quality claims cite exact profile version, model role
  versions, dataset, deadline setting, and date.
- [ ] Missing parity lanes are reported explicitly until they exist.

## POC To Target Mapping

| POC area | Current state | Target | Roadmap phase |
| --- | --- | --- | --- |
| `Cartulary.Memory` | Compatibility facade over Ash actions; F7 retrieval helper retains static SQL | Remove or reduce after F2/F7 surface migration | F1, F2, F7 |
| Accounts | Header-selected local Account key | Identity-derived Account, single-Account free enforcement, RLS | F3 |
| Scopes | Path rows, limited inheritance | Scope tree plus relations, role inheritance, nearest-wins config | F1, F3 |
| Sessions/messages | Basic persistence | Multi-peer sessions, dynamic scope set, raw observations/documents | F1, F6 |
| Knowledge | Simple active rows and minimal lifecycle | Immutable statement, attributions, provenance, relations, ledger, tri-temporal fields | F1, F4 |
| Extraction | OpenRouter-compatible or deterministic fallback | ReqLLM role, structured output, subject/source resolution, temporal/sensitivity proposals | F5 |
| Oban | Direct enqueue, sync by default | AshOban transactional jobs and Reactor orchestration | F2 |
| Gate B | Confidence/sensitivity auto-activation placeholder | Gate matrix, curator/peer routing, consent, blast-radius checks | F4 |
| Retrieval | Inline SQL lexical/temporal/salience with simple fusion | Strategy modules, pgvector, FTS, entity match, relation expansion, RRF, profiles, deadlines | F7 |
| pgvector | Extension enabled, unused | Knowledge/document embedding columns, indexes, backfill, semantic retrieval | F5, F7 |
| Context | Knowledge list only | Projection-backed reasoning-free context assembly | F7 |
| Ask | Simple cited answer over candidates | Grounded dialectic loop with abstention and citation verification | F8 |
| Eval | POC smoke and benchmark adapter | Deterministic PR gate plus release/nightly eval framework | F11 |
| pg0 | Manually launched binary | Pinned, supervised release child with upgrade/runbook | F10 |
| Surfaces | Minimal Phoenix JSON controller | AshJsonApi/OpenAPI, MCP, gateway, LiveView governance, generated SDKs | F8 |
| Projections | Absent | Peer profiles, scope cards, session summaries, incremental refresh and caches | F7 |
| Portability | Absent | Logical export/import and rebuild of derived caches | F10 |

## Feature Coverage Checklist

The free core is complete when all rows below are implemented, tested, and
documented.

| Capability | Required in free core | Enterprise-only or deferred |
| --- | --- | --- |
| Single-node self-host | pg0-supervised release, external Postgres option, stock Postgres container | Queue mode and clustered HA |
| Data layer | AshPostgres, pgvector, PG-FTS, Oban-Postgres everywhere | Schema/db per Account |
| Accounts | One Account, identity-derived, RLS available | Multiple Accounts |
| Auth | Local auth, magic-link, API keys | SSO/SAML/SCIM |
| RBAC | Basic account-admin, curator, member, reader by scope with inheritance | Granular enterprise RBAC and ReBAC adapter |
| Memory model | Natural-language knowledge atom, provenance, lifecycle, relations, tri-temporal fields | Structured triples/knowledge graph |
| Pipeline | Ingest-time and dream-time lanes, AshOban, Reactor, gates, audit | Multi-node scale lanes |
| Governance | Validation queue, peer self-view, contest/redact, consent, revalidation, history/diff | SIEM streaming, extended retention controls |
| Retrieval | Full strategy set, profiles, deadlines, rerank where profile enables it | No retrieval-quality gate unless a human changes the licensing decision |
| Entities | Derived internal entity cache and entity-match retrieval | Public entity surface is prohibited |
| Documents | Native extraction, chunking, embeddings, sync behavior | Enterprise connector fleet operations |
| Surfaces | HTTP/OpenAPI, MCP, gateway proxy, LiveView governance | Enterprise admin/compliance dashboards |
| SDKs | Generated TypeScript and Python clients | None |
| Models | ReqLLM roles, OpenAI-compatible, self-hosted endpoints, Ortex embeddings | Multi-provider in-engine fallback |
| Observability | Health, metrics emission, redacted logs, usage ledger, local cost visibility | Prebuilt enterprise dashboards and SIEM export |
| Portability | Logical export/import, backup/restore docs | Scheduled enterprise backup service |
| Evaluation | Deterministic guardrails and release/nightly eval | None |

## Done Definition

The free-core roadmap is complete when:

1. A fresh user can install and run Cartulary single-node without Docker or a
   preinstalled Postgres on supported platforms.
2. All public writes persist raw observations only; all knowledge writes come
   from the pipeline through Gate A/B.
3. Account and scope isolation are enforced at the Phoenix edge, Ash policies,
   and Postgres RLS.
4. `get_context`, `ask`, `search`, `query_knowledge`, and `check_readiness`
   work through HTTP, MCP where applicable, generated SDKs, and the gateway.
5. `get_context` is reasoning-free and projection-backed.
6. `ask` is grounded, cited, and able to abstain.
7. The validation queue, peer self-view, revalidation, contest/redact, erasure,
   audit, and history/diff flows are usable.
8. Documents are dual-ingested into chunks/embeddings and governed knowledge.
9. Export/import round-trips an Account into a fresh instance and rebuilds
   derived caches.
10. The deterministic PR gate and release/nightly eval lanes provide real,
    current evidence for correctness, quality, latency, token efficiency, and
    backend parity.

## Sequencing Rules

- Keep each implementation issue tied to one phase and one clear acceptance
  slice.
- Do not add enterprise-only code to complete a free-core feature.
- Do not merge a feature whose public surface bypasses Ash actions.
- Do not publish a quality number without profile version, model role versions,
  dataset, deadline setting, and date.
- Do not convert a POC shortcut into a permanent pattern without updating the
  relevant ADR or blueprint anchor.
