# Cartulary agent operating contract

This file is the top-level operating contract for agents and human contributors
working in this repository. It applies to the entire repository tree unless a
more deeply nested `AGENTS.md` overrides it for a subdirectory.

Cartulary is a community beta at version `0.2.0`. It is no longer a proof of
concept. Capabilities are named literally throughout this document; the former
`F0`–`F11` phase labels are retired.

## Read first

Before editing, read the smallest authoritative set needed for the task:

1. This `AGENTS.md`.
2. The relevant blueprint anchors in:
   - `specs/memory-system-functional-requirements.md`
   - `specs/memory-system-architecture-and-nfr.md`
   - `specs/memory-system-product-blueprint.md`
3. `docs/roadmap/beta-roadmap.md` — the only roadmap. It carries the
   outstanding work, the delivery workflow, and the maintainer-owned GitHub
   setup.
4. `docs/implementation-status.md` — what actually runs today, its verification
   evidence, and its real limitations.
5. `docs/architecture/free-core-architecture.md` — target decomposition,
   abstraction layers, durable-versus-derived rules, the public operation set,
   and the contract version identities.
6. Any ADRs, architecture notes, eval notes, security notes, or nested
   instructions that govern the files you will touch.
7. For observability, tracing, logging, telemetry, evaluation instrumentation,
   experiment comparison, CI, versioning, or release-readiness work, also read
   `specs/memory-system-evaluation-framework.md`,
   `docs/observability/README.md`, and
   `docs/architecture/evaluation-ci-release-readiness.md`.
8. For work touching Ash resources, actions, policies, tenancy, or migrations,
   also read `docs/architecture/ash-domain-backbone.md`.
9. For document ingestion, blob storage, parsing, connectors, sync,
   supersession, or document portability, also read
   `docs/architecture/documents-connectors-sync.md`.

Blueprint anchors are stable review handles. Preserve existing `FR-*`, `AD-*`,
`AINV-*`, `NFR-*`, and `EV-*` meanings unless the task explicitly asks for a
blueprint change.

## Prime directive

Cartulary follows the ARCH prime directive:

> One codebase, two deployment modes, identical guarantees.

Single-node and queue-mode are the same Mix release with different adapters and
runtime configuration, never forks or simplified reimplementations. Free/core
and enterprise code may be licence-gated, but the community build must remain
coherent and buildable in isolation.

## Architecture posture

Cartulary is an Elixir/Ash/Phoenix/Oban system:

- **Runtime:** Elixir on the BEAM; one Mix release, no second engine runtime.
- **Domain model:** Ash Domains, Resources, Actions, policies, and data layers
  carry the ports-and-adapters structure.
- **Surfaces:** Phoenix HTTP, LiveView, Channels/PubSub, AshJsonApi, gateway
  proxy, and the `ash_ai` MCP server where appropriate.
- **Jobs:** Oban through AshOban on the Postgres engine in every deployment
  mode. Do not introduce Redis/BullMQ, `Oban.Engines.Lite`, or a separate
  worker fleet.
- **Storage:** AshPostgres + pgvector + Postgres FTS in every deployment mode.
  Local single-node uses pg0 as the embedded Postgres launcher; queue-mode uses
  an operator-run Postgres. Keep vector/lexical indices and projections as
  rebuildable derived caches.
- **Models:** provider-neutral model roles over ReqLLM; self-hosted and
  OpenAI-compatible endpoints must remain possible. Default embedding strategy
  should remain compatible with local/offline Ortex/ONNX.
- **Extraction/retrieval:** prefer native Elixir/Rust/C-NIF integrations already
  named by the blueprint (Extractous/MDEx, `bitcrowd/rag`, hnswlib) before
  bespoke infrastructure.

## Non-negotiable product and architecture invariants

Treat these as hard constraints during design, implementation, review, and
refactoring:

1. **Context flows down freely; knowledge flows up only through Gate B.**
2. **Agents submit raw observations only; the pipeline is the sole writer of
   knowledge.**
3. **Blast radius scales the bar:** wider exposure requires stronger confidence,
   sensitivity handling, and consent.
4. **Knowledge is the only atom; profiles, scope cards, and session summaries
   are projections.**
5. **Reasoned artifacts pass validation gates; authored artifacts use plain
   versioning.**
6. **Belief-time, valid-time, and salience are independent; confidence and
   sensitivity are independent; subject and source are independent.**
7. **Everything scoped inherits down the containment tree, nearest-wins.**
8. **Cross-account isolation is absolute. Account is derived from identity, not
   from request parameters.**
9. **The user owns the data and keys.** Core paths must not require a proprietary
   managed service.
10. **System of record and derived caches are distinct.** Raw messages,
    validated knowledge, and audit logs are durable; queues, projections,
    lexical/vector indices, HNSW, ETS, and `persistent_term` caches are
    rebuildable.
11. **Transactional integrity is mandatory.** State changes, audit entries, and
    Oban enqueue/outbox effects that belong to one operation commit together.
12. **Infrastructure ports and domain strategies are different seams.** Pointing
    the release at pg0 or an operator-run Postgres changes where Postgres lives,
    not product behavior; swapping a retrieval or gate strategy changes behavior
    and needs explicit review.

## Contract version identities

Several public contracts carry their own version string, independent of the
application's semantic version. The `f`-prefixed identities are historical
version tags. They no longer name a roadmap phase, and they must not be renamed
casually:

| Identity | Covers |
| --- | --- |
| `poc-0` | Frozen behaviour baseline and the historical evaluation reports. |
| `f4-1` | Governed lifecycle: proposals enter `proposed`/`provisional` or are held. |
| `f5-1` | Extractor and pipeline identity, reported by `GET /api/health`. |
| `f7-1` | Retrieval and context profile identity. |
| `f9-1` | Skill selector language and gap-report schema. |
| `f10-1` | Readiness payload shape. |
| `f11-1`, `f11-suite-1` | Evaluation report schema and release bundle. |
| `f11-surface-contracts-1` | Surface contract inventory schema. |
| `cartulary-account-1` | Logical Account archive schema. |

Changing any of them is a deliberate contract transition. It needs a changelog
entry, updated contract evidence, and a note in the closest architecture
document.

## Development discipline

### Coding conventions

**Source files are the primary documentation.** A competent Elixir developer
who has never opened `specs/` or `docs/` must be able to open any file in this
repository and understand, from that file alone, what it does, why it exists,
which rules it enforces, and what a caller may not do with it.

- **Explain in place; never delegate the explanation.** A comment or docstring
  must not offload its meaning onto a spec, an architecture note, a roadmap
  item, an issue, or a blueprint anchor. Do not write `see
  docs/architecture/...`, `per FR-KN-3`, or `AD-DATA-1 requires this` in
  source. State the rule itself, in plain language, at the place that enforces
  it. Traceability belongs in commit messages, PR descriptions, ADRs, and the
  `docs/` tree — not in code comments. Pointing at a file for *data* (a
  fixture path, a threshold file the code actually reads) is fine; pointing at
  a document for *understanding* is not.
- **No retired phase labels.** `F0`–`F11` no longer name anything, and must
  never appear in a comment or docstring. Contract version identity *values*
  such as `f7-1`, `poc-0`, or `cartulary-account-1` are data, not labels: keep
  the string and explain beside it which contract it versions and what
  changing it obliges you to do.
- **Every module carries a real `@moduledoc`.** No bare `@moduledoc false` in
  first-party code. A moduledoc answers, in order: what this module is, what
  it owns, the invariants it guarantees, and the mistakes callers must avoid.
  A module that must stay out of generated docs may keep `@moduledoc false`
  only when an equivalent `#` comment block with the same content sits
  immediately above or below it.
- **Every public function carries an `@doc`,** except in files that are pure
  DSL declarations (an Ash domain listing resources, a `use`-only module). The
  docstring gives purpose, the meaning of non-obvious arguments, the return
  shape, and the failure modes a caller must handle — including which variants
  raise.
- **Comment the why, never the what.** `# increment the counter` above
  `count + 1` is noise; delete it. Comment ordering constraints, transaction
  boundaries, tenancy filters, replay and idempotency requirements,
  content-safety redaction, deliberately non-obvious algorithms, workarounds,
  and anything a future reader would otherwise "clean up" and break.
- **Give constants a unit and a reason.** Timeouts, limits, weights,
  thresholds, retry counts, and buffer sizes get a comment naming the unit and
  why that value was chosen.
- **Document Ash resources inline.** Say what one row means, which actions are
  reachable only by the internal pipeline, why an action is create-only or
  append-only, what each custom change or validation enforces, and what the
  multitenancy and policy blocks actually guarantee.
- **Document DSL blocks that encode a rule.** Policies, multitenancy,
  identities, Oban triggers, and hand-written index or row-level-security DDL
  need a sentence stating the guarantee, not a restatement of the DSL syntax.
- **Non-Elixir files count too.** Shell launchers, `Dockerfile`, Compose
  files, CI workflows, config files, schema-bearing JSON, and the `sdk/`
  helpers open with a header comment stating purpose, inputs, outputs, and
  assumptions. Keep the SPDX line first where the format allows comments.
- **Comments are part of the change.** A behaviour edit updates the
  surrounding comment in the same patch. A stale comment is a defect; a
  comment that contradicts the code is reviewed as a bug.
- **Exempt trees.** Generated and historical artifacts are not rewritten for
  style: `deps/`, the generated migrations under `priv/repo/migrations/`, the
  resource snapshots under `priv/resource_snapshots/`, recorded evaluation
  reports under `docs/eval/results/`, and committed JSON fixtures. New
  migrations still get comments on hand-written DDL, because that DDL is
  authored, not generated.
- **Existing evidence identities keep their names.** Test files and modules
  whose paths are cited as regression evidence elsewhere in this contract are
  renamed only by a deliberate, contract-updating change. Make them
  self-explanatory with a moduledoc that states which behaviour the file pins
  and why, rather than by renaming.

### Traceability

- Keep each change traceable to the task, issue, and blueprint anchors it
  implements. Record that trace in the commit message, the PR description, and
  the durable documents under `docs/` — not in source comments, which must
  stand alone.
- Use `docs/roadmap/beta-roadmap.md` as the execution map. It does not replace
  the blueprint specs; it decomposes their remaining free-core scope into
  tracks and acceptance slices.
- Roadmap checkboxes are evidence markers. Mark an item `[x]` only when
  implementation, regression evidence, and the closest durable documentation
  are present and current; return it to `[ ]` if that evidence is removed or
  fails.
- Implement only the requested scope. Do not opportunistically add
  later-roadmap artifacts unless the current task explicitly asks for them.
- You are not alone in this codebase. Inspect the worktree before editing,
  avoid overwriting concurrent changes, and never revert or rewrite another
  person's edits unless the task explicitly authorizes it.
- Prefer small, reviewable patches. One behavior change should have one obvious
  home and one obvious set of tests.
- Keep docs, code, tests, eval fixtures, and ADRs aligned. If behavior changes,
  update the closest durable documentation or explain why no doc update is
  needed.
- Keep `mix.exs`, `CHANGELOG.md`, release tags, protocol/report identities, and
  release artifacts aligned. Every release has a dated changelog entry citing
  the closest blueprint/architecture anchors.

### Baseline API contract

- The frozen behaviour baseline is the regression floor. Changes to HTTP
  behavior, Account selection, downward scope inheritance, raw-message
  persistence, pipeline-only knowledge writes, lifecycle insertion,
  deterministic fallback, or normalized eval fixtures must update the
  corresponding contract evidence and document whether the contract identity
  remains `poc-0` or is intentionally versioned.
- Baseline evidence is `test/cartulary/poc_contract_test.exs`,
  `test/cartulary_web/controllers/memory_controller_test.exs`,
  `test/cartulary/eval/fixture_contract_test.exs`, and
  `test/fixtures/eval/poc-contract-baseline.json`. Run those tests before and
  after any internal migration slice.

### Ash domain backbone

- Ten configured Ash Domains and 38 Resources are the authoritative durable
  data boundary. Do not add durable writes outside Ash actions.
- Evidence: `test/cartulary/f1_ash_domain_backbone_test.exs`,
  `priv/resource_snapshots/`, and the generated migrations under
  `priv/repo/migrations/`. Design notes:
  `docs/architecture/ash-domain-backbone.md`.
- Keep Ash resources and `priv/resource_snapshots/` synchronized. Resource
  changes must use `mix ash.codegen`, manually review generated migrations, and
  keep custom pgcrypto/pgvector/FTS/index/RLS DDL intact.
- Direct Repo/Ecto SQL access is confined to infrastructure/data-layer modules
  and explicitly ticketed custom query helpers. The current exceptions are:
  - `Cartulary.Retrieval.Store` — read-only helper for static, parameterized
    PG-FTS, pgvector ANN, and hop-one expansion queries. It performs no durable
    write and must keep all authorization filters inside each query.
  - `Cartulary.Pipeline.Lock` — infrastructure helper for parameterized
    transaction-scoped advisory locks. It performs no durable write.
  - `Cartulary.Identity.CredentialLocator` — bootstrap helper that maps only an
    opaque AshAuthentication API-key id to `account_id` through the reviewed
    security-definer function before Account RLS can be installed.

  New exceptions require a named roadmap/issue transition and durable
  documentation.

### Transactional writes, audit, and jobs

- `Cartulary.Operations.PipelineRun` makes raw observation, content-safe
  hash-chain audit, durable idempotency record, and AshOban enqueue one
  transaction. Do not enqueue pipeline work outside the `PipelineRun` Ash
  actions.
- Evidence: `test/cartulary/f2_transactional_writes_audit_jobs_test.exs` and
  `docs/architecture/transactional-writes-audit-jobs.md`.
- Pipeline execution is replay-safe. New jobs need a deterministic key in
  `Cartulary.Pipeline.Idempotency`; durable source records need a reconciler
  path; and content-bearing values must not be copied into audit metadata or
  Oban arguments.

### Identity, tenancy, and RBAC

- `Cartulary.Accounts.ApiKey` makes HTTP Account selection identity-derived,
  enforces one authenticated community Account, and resolves deny-wins
  inherited basic roles. Do not reintroduce request-selected Account identity,
  store plaintext API keys, or bypass `Cartulary.Identity.RoleResolver` for
  authenticated scope reads.
- Evidence: `test/cartulary/f3_identity_tenancy_basic_rbac_test.exs`,
  `test/cartulary_web/controllers/memory_controller_test.exs`, and
  `docs/architecture/identity-tenancy-rbac.md`.
- Role grants use exactly `account-admin`, `curator`, `member`, and `reader`
  with `allow|deny` effects and per-grant propagation. Any applicable deny
  removes access to that scope. Cross-linked scope reads require access to both
  relation endpoints; a cross-link never grants access.

### Gate A/B governance

- New extracted knowledge must enter `proposed` and pass
  `Cartulary.Governance.Engine`. Do not reintroduce auto-activation outside the
  versioned Gate matrix.
- Evidence: `test/cartulary/f4_real_gate_a_b_governance_test.exs` and
  `docs/architecture/gate-a-b-governance.md`.
- Curator decisions are human-only. Machine credentials and MCP may submit raw
  observations, read governed memory, resolve only the calling peer's frozen
  inline question, and lower that peer's ask limits; they must never expose or
  invoke approve, edit, reject, merge, defer, promotion, Gate-rule
  administration, or bulk curator actions.
- Scope and account proposals remain `held` and absent from retrieval until
  Gate B approval. Upward personal knowledge additionally requires
  target-specific, verified subject consent; curator approval cannot substitute
  for that consent. Every automatic and human gate result must preserve
  immutable decision, lifecycle, content-safe audit, and replay-keyed
  continuation evidence.
- Erasure goes through `Cartulary.Governance.Erasure`. Proportionate erasure
  removes subject content and scrubs shared provenance; strict erasure removes
  all knowledge sourced only through the subject path. Both must recompute or
  dirty affected projections/entities while retaining content-safe audit
  evidence. Inline delivery text is erasable and must not be copied into audit,
  telemetry, or Oban arguments.

### Model layer and structured extraction

- All model calls go through `Cartulary.Model.Gateway`. Do not invoke ReqLLM or
  a provider adapter from pipeline, retrieval, web, or governance code.
- Evidence: `test/cartulary/f5_model_layer_structured_extraction_test.exs`,
  `test/fixtures/model/f5-provider-cassette.json`, and
  `docs/architecture/model-layer-structured-extraction.md`.
- There are exactly four Account-level roles: `embedder`, `ingest_extractor`,
  `dream_reasoner`, and `dialectic_agent`. Persist secret references only, keep
  per-scope role overrides deferred, and preserve provider/model/version plus
  prompt/pipeline provenance. `Cartulary.Model.Usage` is the only durable usage
  emission point; keep its events and model spans content-safe.
- Structured extraction and reasoning use the Ash-derived schemas and bounded
  repair in `Cartulary.Model.StructuredGenerator`. Do not accept malformed
  provider output, bypass pipeline-only knowledge writes, collapse subject into
  source, omit hearsay discounting, or skip governance. Provider failures must
  leave raw observations and jobs retryable, and `get_context` must remain
  model-free.
- Embedding identity includes provider, model, version, and dimensions. A
  mismatch must return the versioned re-embed path and must never reuse or
  silently substitute vectors. The deterministic provider is test/local-only;
  production must not fall back to it after a provider error.

### Documents, connectors, and sync

- Connectors submit raw document versions only. Extracted knowledge must still
  pass the structured extraction pipeline and Gate A/B governance.
- Evidence: `test/cartulary/f6_documents_connectors_sync_test.exs` and
  `docs/architecture/documents-connectors-sync.md`.
- Connector cursors advance only after a page is durably handled. Repeated
  content hashes are no-ops, changed documents append immutable versions and
  supersede stale derivations without overwriting history, and remote deletion
  uses tombstones. Supersession and tombstones must not retract knowledge with
  surviving independent provenance. Blob adapter choice is a runtime
  infrastructure seam and must not change those semantics.
- Document chunks and embeddings are rebuildable derived caches. Logical export
  includes checksum-verified version blobs and metadata but excludes
  chunks/vectors; import rebuilds through ordinary ingest. Erasure must remove
  exclusive blobs and document-only knowledge while preserving content-safe
  audit evidence and knowledge with surviving provenance. Never copy document
  bytes, extracted text, connector cursors, source metadata, or secrets into
  audit metadata, telemetry, or Oban arguments.

### Retrieval, entity resolution, and context

- `Cartulary.Retrieval.Strategy` is the retrieval boundary and
  `Cartulary.Context` is the reasoning-free projection assembly boundary.
  `search` defaults to `:balanced`, `ask` to `:thorough`, and only the `:fast`
  profile may run live on a `get_context` projection miss.
- Evidence: `test/cartulary/f7_retrieval_entity_context_test.exs` and
  `docs/architecture/retrieval-entity-context.md`.
- Retrieval must apply Account, authorized scope, lifecycle, provisional
  subject, and source filters before candidates leave retrieval internals.
  Strategy-local scores are not comparable: merge with weighted
  reciprocal-rank fusion, compute disagreement before fusion, enforce the
  remaining deadline around strategies and reranking, and report contributed
  and dropped strategies. Raw strategy overrides remain internal/eval-only.
- `Entity` and `EntityMention` rows are rebuildable, pipeline-internal caches.
  Never expose entity rows, canonical names, aliases, surface forms, or entity
  ids through Phoenix, MCP, SDK, LiveView, projection payloads, or retrieval
  responses. Erasure and import must recompute them from surviving governed
  statements. Scope relations and shared-entity edges may expand retrieval only
  after both endpoint scopes pass the caller's authorization.
- Vectors carry provider, model, version, and dimensions. A mismatch follows the
  explicit re-embed path; never reuse or silently substitute vectors. Keep
  knowledge/chunk/entity HNSW indexes and statement/chunk PG-FTS indexes
  synchronized with resource and migration changes. Projection changes must
  preserve dirty marking, bounded delta compaction, source ids, and PubSub/ETS
  invalidation; normal `get_context` assembly must not call a reasoning model.

### Skill readiness and procedural memory

- Skill requirement cards are human-authored, plain-versioned procedural
  memory. They are not knowledge and do not pass Gate A/B. Requirement keys
  inherit down the scope tree with nearest-scope overrides.
- Evidence: `test/cartulary/f9_skill_readiness_procedural_memory_test.exs` and
  `docs/architecture/skill-readiness-procedural-memory.md`.
- Readiness may be satisfied only by authorized `active` knowledge or the
  calling peer's usable `provisional` knowledge. Expired, due-for-revalidation,
  and `needs_revalidation` items remain gaps even before a sweeper runs.
- Required gaps block helper execution and preferred gaps only warn.
  `ask-peer` and `either` gaps may produce an elicitation prompt, but the
  answer must return through ordinary raw `ingest` and governance before
  readiness is checked again. SDK helpers must never override a server blocker
  or write knowledge directly.

### Portability, packaging, and operations

- The same release runs in supervised-pg0 and external-Postgres modes. Keep pg0
  version and platform SHA-256 values pinned, run it before Repo and
  migrations, and never add pg0 to the container path or fork behavior by
  database mode.
- Evidence: `test/cartulary/f10_portability_packaging_operations_test.exs`,
  `docs/architecture/portability-packaging-operations.md`, `docs/operations/`,
  `rel/`, `Dockerfile`, and `compose.yml`.
- Logical Account archives use schema `cartulary-account-1`, keyset-stream
  durable resources, include checksum-verified original blobs, and verify the
  entire audit graph before any durable import. Credentials, password hashes,
  secrets, vectors, chunks, projections, entities, entity mentions, and
  extracted-text caches must remain excluded. Imports require a fresh target,
  write only through the private Ash portability actions in one Account-scoped
  transaction, and enqueue replay-keyed ordinary rebuild work.
- Operations remain content-safe. `/api/ready` may expose component status,
  queue counts, model identities, versions, and error classes; it must never
  expose credentials or content. Exact API/model usage stays in `UsageEvent`,
  ETS budget counters remain rebuildable, dream-time is throttled first, and
  self-host cost visibility uses operator-provided rates rather than hidden
  billing state. Production structured logs retain only the reviewed metadata
  allowlist.

### Evaluation, CI, and release readiness

- Application releases use Semantic Versioning; evaluation evidence uses the
  `f11-1` report identity. A release must not proceed when a deterministic
  guardrail, external-Postgres or pg0 lane, release/container build, semantic
  tag/changelog check, report provenance check, or committed
  correctness/citation floor fails.
- Evidence: `test/cartulary/f11_evaluation_ci_release_readiness_test.exs`,
  `specs/memory-system-evaluation-framework.md`,
  `docs/architecture/evaluation-ci-release-readiness.md`, `docs/eval/`,
  `.github/workflows/`, and `CHANGELOG.md`.
- Public benchmark and quality claims require the exact application and
  retrieval-profile versions, all four model-role versions, dataset id/SHA-256
  and split, deadline setting, date, judge identity, strategy override, and run
  limits. Quality, latency, token efficiency, and degradation remain
  frontier-tracked; do not turn them into gates without an explicit reviewed
  threshold change. Fusion weights may use only held-out tuning data.
- Integration surfaces, gateway, and generated SDKs are **not implemented**.
  The skill-readiness helpers under `sdk/` are not generated SDKs, and `0.2.0`
  has no generated AshJsonApi OpenAPI contract. Keep unavailable surfaces
  explicit in `docs/eval/surface-contract-inventory.json`; do not advertise
  them as shipped or silently omit their missing lane.

### Observability and safety

- Keep observability content-safe. Traces and logs may record ids, counts,
  profile names, model names, strategy names, timings, token counts, and error
  classes; they must not record raw messages, prompts, answers, API keys,
  account keys, peer keys, restricted knowledge, or secrets.
- Preserve per-request trace correlation. HTTP responses should expose
  `x-trace-id`; callers with W3C `traceparent` should keep their incoming trace
  id, and callers without one should get a newly generated request trace id.

### Things not to do

- Do not invent architecture that bypasses Ash, Phoenix, Oban, or the blueprint
  seams. If a new seam is unavoidable, document the reason and cite anchors.
- Do not put `try`/`catch` or equivalent defensive wrappers around imports or
  aliases. Fix dependency/configuration problems directly.
- Do not rename a historical artifact that carries evidence. The migration
  filenames under `priv/repo/migrations/`, the `pipeline_version` defaults
  baked into old migrations and resource snapshots, and the recorded `poc-0`
  evaluation reports under `docs/eval/results/` are immutable. Renaming a live
  default such as the `/poc` scope path is a versioned behaviour change with
  its own roadmap item, not incidental cleanup.

## Licensing discipline

Cartulary is fair-code / source-available, modelled on the blueprint's
open-core stance:

- Community/core files are governed by `LICENSE.md` and should carry
  `SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0` when the file format
  supports comments.
- Enterprise-only files are governed by `LICENSE_EE.md`, must live under an
  `ee` directory or use `.ee.` in the filename, and should carry
  `SPDX-License-Identifier: Cartulary-Enterprise`.
- Do not add enterprise-gated behavior, move a feature across the license
  boundary, or change entitlement semantics unless a human has explicitly made
  that licensing decision in an issue, ADR, or blueprint update. ADR-0002 treats
  licensing boundaries as human-only decisions.
- The community build must remain coherent and buildable without enterprise
  code. Core must not import enterprise modules; enterprise code may depend on
  core through the explicit OTP app / runtime entitlement boundary described by
  `AD-TOPO-3` and `AD-CFG-3`.
- Gate scale, operations, governance, compliance, and support by license. Do not
  gate core answer quality or retrieval correctness unless the maintainer
  resolves the open ADR-0004 licensing question differently.
- Never remove, alter, or obscure copyright, license, or SPDX notices.
- Third-party code and vendored dependencies keep their upstream licenses. Do
  not add Cartulary SPDX headers under `deps/` or other vendored trees.

## Required local checks before opening a PR

Run the checks that exist for the repository state you are editing and report
all results in the PR and final response. When a command is unavailable, state
that explicitly rather than fabricating evidence.

Minimum checks for every task:

```bash
git status --short
```

The standard Elixir gate:

```bash
mix deps.get
mix ash.codegen --check
mix format --check-formatted
mix compile --warnings-as-errors
mix test
```

Also run, when the change touches the relevant area:

```bash
mix credo --strict
mix dialyzer
mix sobelow --config
```

For evaluation, CI, versioning, or release-readiness changes, also run:

```bash
mix cartulary.eval.release \
  --no-model \
  --assert-thresholds \
  --output /private/tmp/cartulary-release-eval.json
mix cartulary.release.check \
  --eval-report /private/tmp/cartulary-release-eval.json
```

The pg0 CI lane additionally runs `scripts/ci-pg0-lane`; it downloads the
checksum-pinned pg0 asset, so local execution requires network access. The
external-Postgres and packaged-pg0 job names and the release procedure are in
`docs/operations/release-checklist.md`.

For documentation-only changes, inspect the changed Markdown directly and run
any available repo-local Markdown or link check. If no such tool exists, say so
and include the manual inspection scope.

For changes touching local single-node and queue-mode behavior, provide parity
evidence for pg0-backed and operator-run Postgres paths. Clearly mark any lane
you could not run.

## Review guidance

Reviewers and agents should ask:

- Does the change preserve the prime directive: one codebase, two modes,
  identical guarantees?
- Does it maintain Account isolation, downward inheritance, governed upward
  promotion, and pipeline-only knowledge writes?
- Does it distinguish durable stores from rebuildable caches?
- Are Oban jobs, audit writes, lifecycle transitions, and derived-index updates
  transactionally safe?
- Does it avoid provider, database, deployment-mode, or cloud lock-in?
- Are Free/Core and Enterprise boundaries explicit and non-forking?
- Are blueprint anchors cited in the PR description and the durable docs where
  the design depends on them — and kept out of source comments?
- Can every touched file be read and understood on its own, without opening
  `specs/` or `docs/`? Does each comment explain a reason rather than restate
  the code?
- Are test results real, current, and scoped to the change?
- Is the PR focused on one task, with no unrelated cleanup or roadmap creep?

Security-, tenancy-, audit-, pipeline-, backend-parity-, or eval-sensitive work
needs explicit reviewer attention and evidence matching that risk class.

## Delivery discipline

One task, one issue, one branch, one PR. The full workflow, the label taxonomy,
and the maintainer-owned GitHub settings that are still outstanding are in
`docs/roadmap/beta-roadmap.md`.

1. A human scopes and labels exactly one implementation issue as `ai-ready`.
2. The agent reads this contract, the blueprint anchors, and the closest
   architecture note before editing.
3. The agent implements only that issue's acceptance criteria.
4. The agent opens one focused PR with real check evidence and links the issue.
5. A human reviews and remains the merge gate.
6. The next task starts only after merge, from the updated `main`.

Do not batch unrelated tasks. Repository rulesets, required checks, protected
secrets and environments, publishing permissions, and Codex integration are
maintainer-owned GitHub settings: the presence of a workflow file is not
evidence that `main` is protected.
