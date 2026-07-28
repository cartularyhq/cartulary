# Cartulary agent operating contract

This file is the top-level operating contract for agents and human contributors
working in this repository. It applies to the entire repository tree unless a
more deeply nested `AGENTS.md` overrides it for a subdirectory.

## Read first

Before editing, read the smallest authoritative set needed for the task:

1. This `AGENTS.md`.
2. The relevant blueprint anchors in:
   - `specs/memory-system-functional-requirements.md`
   - `specs/memory-system-architecture-and-nfr.md`
   - `specs/memory-system-product-blueprint.md`
3. For automation/process work, also read:
   - `docs/roadmap/l3-automation-flow.md`
   - `docs/roadmap/manual-automation-setup.md`
4. Any ADRs, architecture notes, eval notes, security notes, or nested
   instructions that govern the files you will touch.
5. For work touching the current local POC, also read
   `docs/poc-local-proof.md`.
6. For work migrating the POC toward the complete free self-host core, also read
   `docs/roadmap/free-core-roadmap.md`.
7. For observability, tracing, logging, telemetry, evaluation instrumentation,
   or experiment-comparison work, also read `docs/observability/README.md`.
8. For work touching Ash resources, actions, policies, tenancy, or migrations,
   also read `docs/architecture/f1-ash-domain-backbone.md`.
9. For document ingestion, blob storage, parsing, connectors, sync,
   supersession, or document portability, also read
   `docs/architecture/f6-documents-connectors-sync.md`.

Blueprint anchors are stable review handles. Preserve existing `FR-*`, `AD-*`,
`AINV-*`, and `NFR-*` meanings unless the task explicitly asks for a blueprint
change.

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

## Development discipline

- Keep each change traceable to the task, issue, and blueprint anchors it
  implements.
- Treat the current local POC as a checkpoint, not as finished architecture.
  Its implemented scope, shortcuts, and required refactors are logged in
  `docs/poc-local-proof.md`. Do not convert a POC shortcut into a permanent
  pattern without updating the relevant ADR/spec and citing the reason.
- Use `docs/roadmap/free-core-roadmap.md` as the execution map for completing
  the free self-host core. It does not replace the blueprint specs; it decomposes
  their free-core scope into architecture boundaries, migration phases, and
  feature coverage.
- Treat the completed F0 `poc-0` contract as the regression floor while
  migrating internals. Changes to POC HTTP behavior, Account selection,
  downward scope inheritance, raw-message persistence, pipeline-only knowledge
  writes, lifecycle insertion, deterministic fallback, or normalized eval
  fixtures must update the corresponding contract evidence and document whether
  the contract remains `poc-0` or is intentionally versioned.
- F0 contract evidence is kept in `test/cartulary/poc_contract_test.exs`,
  `test/cartulary_web/controllers/memory_controller_test.exs`,
  `test/cartulary/eval/fixture_contract_test.exs`, and
  `test/fixtures/eval/poc-contract-baseline.json`. Run those tests before and
  after any POC-to-Ash migration slice.
- F1 makes the nine configured Ash Domains and their 26 Resources the
  authoritative durable-data boundary. F1 evidence is kept in
  `test/cartulary/f1_ash_domain_backbone_test.exs`,
  `priv/resource_snapshots/`, and
  `priv/repo/migrations/20260727142300_f1_ash_domain_backbone.exs`. Do not add
  durable writes outside Ash actions.
- F2 adds `Cartulary.Operations.PipelineRun` as the 27th Resource and makes
  raw observation, content-safe hash-chain audit, durable idempotency record,
  and AshOban enqueue one transaction. F2 evidence is kept in
  `test/cartulary/f2_transactional_writes_audit_jobs_test.exs`,
  `docs/architecture/f2-transactional-writes-audit-jobs.md`,
  `priv/resource_snapshots/`, and the two `202607271507*` migrations. Do not
  enqueue pipeline work outside the `PipelineRun` Ash actions.
- F2 pipeline execution is replay-safe. New jobs need a deterministic key in
  `Cartulary.Pipeline.Idempotency`; durable source records need a reconciler
  path; and content-bearing values must not be copied into audit metadata or
  Oban arguments.
- F3 adds `Cartulary.Accounts.ApiKey` as the 28th Resource, makes HTTP Account
  selection identity-derived, enforces one authenticated community Account,
  and resolves deny-wins inherited basic roles. F3 evidence is kept in
  `test/cartulary/f3_identity_tenancy_basic_rbac_test.exs`,
  `test/cartulary_web/controllers/memory_controller_test.exs`,
  `docs/architecture/f3-identity-tenancy-basic-rbac.md`,
  `priv/resource_snapshots/`, and the `202607271555*`/`202607272055*`
  migrations. Do not reintroduce request-selected Account identity, store
  plaintext API keys, or bypass `Cartulary.Identity.RoleResolver` for
  authenticated scope reads.
- F3 role grants use exactly `account-admin`, `curator`, `member`, and `reader`
  with `allow|deny` effects and per-grant propagation. Any applicable deny
  removes access to that scope. Cross-linked scope reads require access to both
  relation endpoints; a cross-link never grants access.
- F4 adds eight persisted governance Resources and takes the authoritative
  durable boundary to 36 Resources. F4 evidence is kept in
  `test/cartulary/f4_real_gate_a_b_governance_test.exs`,
  `docs/architecture/f4-real-gate-a-b-governance.md`,
  `priv/resource_snapshots/`, and
  `priv/repo/migrations/20260727220024_f4_real_gate_a_b_governance.exs`.
  New extracted knowledge must enter `proposed` and pass
  `Cartulary.Governance.Engine`; do not reintroduce auto-activation outside the
  versioned Gate matrix.
- F4 curator decisions are human-only. Machine credentials and MCP may submit
  raw observations, read governed memory, resolve only the calling peer's
  frozen inline question, and lower that peer's ask limits; they must never
  expose or invoke approve, edit, reject, merge, defer, promotion, Gate-rule
  administration, or bulk curator actions.
- F4 scope/account proposals remain `held` and absent from retrieval until Gate
  B approval. Upward personal knowledge additionally requires target-specific,
  verified subject consent; curator approval cannot substitute for that
  consent. Every automatic/human gate result must preserve immutable decision,
  lifecycle, content-safe audit, and replay-keyed continuation evidence.
- F4 erasure goes through `Cartulary.Governance.Erasure`. Proportionate erasure
  removes subject content and scrubs shared provenance; strict erasure removes
  all knowledge sourced only through the subject path. Both must recompute or
  dirty affected projections/entities while retaining content-safe audit
  evidence. Inline delivery text is erasable and must not be copied into audit,
  telemetry, or Oban arguments.
- F5 replaces the direct POC model client with the provider-neutral
  `Cartulary.Model` boundary and advances extraction/pipeline identity to
  `f5-1`. F5 evidence is kept in
  `test/cartulary/f5_model_layer_structured_extraction_test.exs`,
  `docs/architecture/f5-model-layer-structured-extraction.md`,
  `test/fixtures/model/f5-provider-cassette.json`,
  `priv/resource_snapshots/`, and
  `priv/repo/migrations/20260727231504_f5_model_layer_structured_extraction.exs`.
  All model calls must go through `Cartulary.Model.Gateway`; do not invoke
  ReqLLM or a provider adapter from pipeline, retrieval, web, or governance
  code.
- F5 has exactly four Account-level roles: `embedder`, `ingest_extractor`,
  `dream_reasoner`, and `dialectic_agent`. Persist secret references only, keep
  per-scope role overrides deferred, and preserve provider/model/version plus
  prompt/pipeline provenance. `Cartulary.Model.Usage` is the only durable usage
  emission point; keep its events and model spans content-safe.
- F5 structured extraction and reasoning use the Ash-derived schemas and
  bounded repair in `Cartulary.Model.StructuredGenerator`. Do not accept
  malformed provider output, bypass pipeline-only knowledge writes, collapse
  subject into source, omit hearsay discounting, or skip F4 governance.
  Provider failures must leave raw observations and jobs retryable, and
  `get_context` must remain model-free.
- F5 embedding identity includes provider, model, version, and dimensions.
  Mismatch must return the versioned re-embed path and must never reuse or
  silently substitute vectors. The deterministic provider is test/local-only;
  production must not fall back to it after a provider error.
- F6 adds `Cartulary.Documents` as the tenth configured Ash Domain plus
  `ConnectorConfig` and `DocumentChunk`, taking the authoritative boundary to
  38 Resources. F6 evidence is kept in
  `test/cartulary/f6_documents_connectors_sync_test.exs`,
  `docs/architecture/f6-documents-connectors-sync.md`,
  `priv/resource_snapshots/`, and
  `priv/repo/migrations/20260728082728_f6_documents_connectors_sync.exs`.
  Connectors submit raw document versions only; extracted knowledge must still
  pass the F5 structured pipeline and F4 governance.
- F6 connector cursors advance only after a page is durably handled. Repeated
  content hashes are no-ops, changed documents append immutable versions and
  supersede stale derivations without overwriting history, and remote deletion
  uses tombstones. Supersession and tombstones must not retract knowledge with
  surviving independent provenance. Blob adapter choice is a runtime
  infrastructure seam and must not change those semantics.
- F6 document chunks and embeddings are rebuildable derived caches. Logical
  export includes checksum-verified version blobs and metadata but excludes
  chunks/vectors; import rebuilds through ordinary ingest. Erasure must remove
  exclusive blobs and document-only knowledge while preserving content-safe
  audit evidence and knowledge with surviving provenance. Never copy document
  bytes, extracted text, connector cursors, source metadata, or secrets into
  audit metadata, telemetry, or Oban arguments.
- F7 replaces the POC retrieval helper with
  `Cartulary.Retrieval.Strategy`, takes retrieval profile identity to `f7-1`,
  and makes `Cartulary.Context` the reasoning-free projection assembly
  boundary. F7 evidence is kept in
  `test/cartulary/f7_retrieval_entity_context_test.exs`,
  `docs/architecture/f7-retrieval-entity-context.md`,
  `priv/resource_snapshots/`, and
  `priv/repo/migrations/20260728092147_f7_retrieval_entity_context.exs`.
  `search` defaults to `:balanced`, `ask` to `:thorough`, and only the
  `:fast` profile may run live on a `get_context` projection miss.
- F7 retrieval must apply Account, authorized scope, lifecycle, provisional
  subject, and source filters before candidates leave retrieval internals.
  Strategy-local scores are not comparable: merge with weighted reciprocal-rank
  fusion, compute disagreement before fusion, enforce the remaining deadline
  around strategies and reranking, and report contributed and dropped
  strategies. Raw strategy overrides remain internal/eval-only.
- F7 `Entity` and `EntityMention` rows are rebuildable, pipeline-internal
  caches. Never expose entity rows, canonical names, aliases, surface forms, or
  entity ids through Phoenix, MCP, SDK, LiveView, projection payloads, or
  retrieval responses. Erasure and import must recompute them from surviving
  governed statements. Scope relations and shared-entity edges may expand
  retrieval only after both endpoint scopes pass the caller's authorization.
- F7 vectors carry provider, model, version, and dimensions. A mismatch follows
  the explicit re-embed path; never reuse or silently substitute vectors.
  Keep knowledge/chunk/entity HNSW indexes and statement/chunk PG-FTS indexes
  synchronized with resource and migration changes. Projection changes must
  preserve dirty marking, bounded delta compaction, source ids, and PubSub/ETS
  invalidation; normal `get_context` assembly must not call a reasoning model.
- Direct Repo/Ecto SQL access is confined to infrastructure/data-layer modules
  and explicitly ticketed custom query helpers.
  `Cartulary.Retrieval.Store` is the F7 read-only helper for static,
  parameterized PG-FTS, pgvector ANN, and hop-one expansion queries; it performs
  no durable write and must keep all authorization filters inside each query.
  `Cartulary.Pipeline.Lock` is an F2 infrastructure helper for parameterized
  transaction-scoped advisory locks and performs no durable write.
  `Cartulary.Identity.CredentialLocator` is the F3 bootstrap helper that maps
  only an opaque AshAuthentication API-key id to `account_id` through the
  reviewed security-definer function before Account RLS can be installed. New
  exceptions require a named roadmap/issue transition and durable documentation.
- Keep Ash resources and `priv/resource_snapshots/` synchronized. Resource
  changes must use `mix ash.codegen`, manually review generated migrations, and
  keep custom pgcrypto/pgvector/FTS/index/RLS DDL intact.
- Roadmap checkboxes are evidence markers. Mark an F-phase deliverable or
  acceptance item `[x]` only when implementation, regression evidence, and the
  closest durable documentation are present and current; return it to `[ ]` if
  that evidence is removed or fails.
- Implement only the requested scope. Do not opportunistically add later-roadmap
  artifacts such as `CONTRIBUTING.md`, `SECURITY.md`, PR templates,
  CODEOWNERS, CI workflows, prompt wiring, or automation unless the current task
  explicitly asks for them.
- You are not alone in this codebase. Inspect the worktree before editing, avoid
  overwriting concurrent changes, and never revert or rewrite another person's
  edits unless the task explicitly authorizes it.
- Prefer small, reviewable patches. One behavior change should have one obvious
  home and one obvious set of tests.
- Keep docs, code, tests, eval fixtures, and ADRs aligned. If behavior changes,
  update the closest durable documentation or explain why no doc update is
  needed.
- Keep observability content-safe. Traces and logs may record ids, counts,
  profile names, model names, strategy names, timings, token counts, and error
  classes; they must not record raw messages, prompts, answers, API keys,
  account keys, peer keys, restricted knowledge, or secrets.
- Preserve per-request trace correlation. HTTP responses should expose
  `x-trace-id`; callers with W3C `traceparent` should keep their incoming trace
  id, and callers without one should get a newly generated request trace id.
- Do not invent architecture that bypasses Ash, Phoenix, Oban, or the blueprint
  seams. If a new seam is unavoidable, document the reason and cite anchors.
- Do not put `try`/`catch` or equivalent defensive wrappers around imports or
  aliases. Fix dependency/configuration problems directly.

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
all results in the PR and final response. Some commands below will not be
runnable until the Mix/Phoenix project exists; when a command is unavailable,
state that explicitly rather than fabricating evidence.

Minimum checks for every task:

```bash
git status --short
```

When `mix.exs` exists, run the standard Elixir gate:

```bash
mix deps.get
mix ash.codegen --check
mix format --check-formatted
mix compile --warnings-as-errors
mix test
```

When the relevant tools/configuration exist, also run the applicable checks:

```bash
mix credo --strict
mix dialyzer
mix sobelow --config
```

For documentation-only changes before the project exists, inspect the changed
Markdown directly and run any available repo-local Markdown or link check. If no
such tool exists, say so and include the manual inspection scope.

For changes touching local single-node and queue-mode behavior, provide parity
evidence for pg0-backed and operator-run Postgres paths once those test lanes
exist. Until then, clearly mark the missing lane as not yet available.

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
- Are blueprint anchors cited where the design depends on them?
- Are test results real, current, and scoped to the change?
- Is the PR focused on one task, with no unrelated cleanup or roadmap creep?

Security-, tenancy-, audit-, pipeline-, backend-parity-, or eval-sensitive work
needs explicit reviewer attention and evidence matching that risk class.

## L3 automation discipline

Cartulary's L3 automation flow is one task, one issue, one branch, one PR:

1. A human scopes and labels exactly one implementation issue as `ai-ready`.
2. The agent reads the blueprint docs and applicable repo instructions before
   editing.
3. The agent implements only that issue's acceptance criteria.
4. The agent opens one focused PR with real check evidence and links the issue.
5. A human reviews and remains the merge gate.
6. The next task starts only after merge from the updated main branch.

Do not batch unrelated practical tasks. Prefer inert, reviewable documentation
until repository settings, labels, CI, branch protection, Codex integration,
secrets, and external automation have been configured by a human maintainer.
