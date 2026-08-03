<!-- SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0 -->

# Changelog

All notable Cartulary changes are recorded here. Versions follow Semantic
Versioning. While the public API is pre-1.0, a minor release may intentionally
version an incomplete surface; breaking changes still require an explicit
changelog entry and contract-version transition.

## [Unreleased]

### Added

- Semantic tag builds now remain in GitHub: the packaged Linux release,
  SHA-256, and evaluation report are attached to a GitHub Release, while the
  production container is published to the repository's GHCR package.
- `get_context` now includes scope-bounded `entity_cards` for resolved entities
  with at least three active governed source statements. Each background-built
  card carries a bounded summary, its model provenance, the strictest source
  sensitivity, and its governed statements without exposing entity-cache ids,
  names, aliases, or mention text. The new member is additive; existing
  retrieval behavior and the `f7-1` contract identity are unchanged.


## [0.3.0] - 2026-07-31

### Fixed

- Scope cards and session summaries no longer persist peer-private
  `provisional` statements. Shared projections now contain active knowledge
  only, while a subject-keyed peer profile retains that peer's active and
  provisional knowledge. Context projection keys use a new private audience
  namespace, so clean pre-fix projections are ignored immediately and the
  subject-filtered `fast` fallback covers reads until rebuilt. The public
  `f7-1` payload contract is unchanged; this restores its intended governance
  boundary.
- Lexical retrieval returned nothing for a question. `websearch_to_tsquery`
  joins bare terms with `AND`, so `search` required every content word of the
  query to occur in one governed statement — a bar a single sentence almost
  never clears. The lane that is meant to carry recall when no embedder is
  configured therefore contributed no candidate to any multi-word question,
  and fusion cannot re-rank an empty list. A query that spells a `websearch`
  operator — a quoted phrase, a leading `-`, or `or` — still parses exactly as
  before; any other query now matches statements sharing any of its terms, with
  `ts_rank_cd` ordering by how many terms a statement covers and how densely.
  Document-chunk search changed identically. Matching uses the same lexemes
  `to_tsvector` stored, so the existing GIN indexes still serve both forms and
  no reindex is needed. Retrieval stays inside the `f7-1` contract: no route,
  parameter, response field, or fusion weight changes, and Account, scope, and
  lifecycle filtering is untouched.
- A search response reported a healthy run when every strategy that reads the
  query text had come back empty. `contributed_strategies` was built from every
  strategy that finished, so one that matched nothing was still named a
  contributor, and `disagreement` discarded empty lists before measuring
  anything, so that strategy left no trace in `strategy_count`, `disjoint`, or
  `low_score` either. When only `temporal` and `salience_recency` survived —
  neither of which reads the query — `search` returned the scope in recency
  order, the same page for every question, in a payload whose shape and health
  signals matched a good result. Retrieval now reports three disjoint
  per-strategy outcomes instead of two: `contributed_strategies` (returned
  candidates), the new `empty_strategies` (ran, matched nothing), and
  `dropped_strategies` (disabled, timed out, or failed, unchanged). Each
  strategy declares `query_dependent?/0`, and `disagreement` gains
  `query_dependent_empty`, true when no query-reading strategy contributed.
  It is still computed before fusion (FR-API-29), which is what lets it say
  "nothing was found" while a full ranked list is being returned.
  `strategy_count`, `disjoint`, and `low_score` keep their current meanings and
  values. `search` and `ask` responses carry one new top-level field and one new
  `disagreement` key; a caller counting `contributed_strategies` will now see
  only the strategies that actually voted on the order. The `search` telemetry
  span adds `cartulary.retrieval.empty_strategy_count` and
  `cartulary.retrieval.query_dependent_empty`, and the console retrieval preview
  names empty strategies alongside dropped ones. `ask` does not yet abstain on
  the new signal; that remains the tracked roadmap item, which this change
  supplies the missing input for. No contract identity changes: `f7-1` still
  names retrieval behaviour, and the addition is backward compatible for a
  caller reading fields by name.
- `ask` no longer discards grounded answer text and validated citations when
  the dialectic model marks its conclusion inconclusive. A response may now
  combine `abstained: true` with non-empty `citations`: the cited statements
  support the qualified text but do not establish a conclusion. Responses with
  no surviving retrieved citation still return the empty `not known`
  abstention, so invented citation ids cannot make unsupported prose public.
  This changes the response shape that API and MCP consumers may observe without
  changing its fields or the `f7-1` retrieval/context contract identity.
- Made observation ingest strictly asynchronous. HTTP and MCP now acknowledge
  with the durable message id before any model call, and the removed
  `sync_extract` option can no longer run extraction in the request. HTTP
  callers can poll the Account- and scope-authorised ingest-status route for
  pending, failed, or completed work and visible governed knowledge. Operators
  can enqueue reconciliation independently of ingest. Evaluation and smoke
  commands invoke their direct extraction entrypoint explicitly. Extraction
  failure logs retain only ids, attempt count, and error class. This is the
  intentional pre-1.0 ingest response-contract transition tracked by issue
  #65; the `f5-1` pipeline identity is unchanged because its governed extraction
  semantics did not change.
- A failed extraction reported `:missing_structured_object` no matter why the
  model call produced nothing, which left an operator reading a trace unable to
  tell a transient upstream blip from a failure that will repeat on every
  retry. A hosted aggregator can answer HTTP 200 with a choice whose finish
  reason is `error` — its own upstream failed part-way through generating —
  and `Cartulary.Model.Providers.ReqLLM` saw only that the response carried no
  object. It reported the same name for a response cut off at the output cap
  and for one the endpoint withheld, and that name became the `error.type` on
  the model span and the error class on the usage event. Incomplete responses
  are now classified by how the response ended: `provider_upstream_error`
  (transient; the job retry is the fix), `provider_output_truncated` (repeats
  identically until `CARTULARY_MODEL_MAX_TOKENS` is raised or
  `CARTULARY_MODEL_REASONING_EFFORT` lowered), `provider_content_filtered`
  (repeats until the input or model changes), and the original
  `missing_structured_object` / `missing_text_response` for a call that
  finished normally and simply returned nothing usable. `chat/3` additionally
  treats blank text as no text, which its documented contract already
  promised, rather than returning an empty string as a successful answer.
  Failures remain returned rather than raised and the caller's job remains
  retryable, so no observation is lost. No route, parameter, response field, or
  contract identity changes.
- Nothing ingested through `POST /api/v1/ingest` was ever extracted on a fresh
  install once the database role became one that row-level security actually
  applies to. The request returned `200` and the observation was stored, but the
  extraction job it queued cancelled itself milliseconds later with
  `{:cancel, :trigger_no_longer_applies}`, so no knowledge was proposed and no
  search could find anything. A background job runs with no request behind it,
  so the pooled connection its first query lands on has no Account declared to
  the database, and the row-level security policy on `pipeline_runs` hides every
  row until one is. The job runner reads its own run row back before any
  Cartulary code runs; finding nothing, it concluded its trigger no longer
  applied and cancelled cleanly while the work stayed outstanding. The same gap
  sat on the write side, where an undeclared status update matched no row and
  surfaced as a stale record. This affected all eleven lanes — extraction,
  dream-time, revalidation, expiry, projection refresh, connector sync, import
  rebuild, reconciliation, entity resolution, validation continuation, and
  answer correlation — not extraction alone. Every trigger now reads through the
  new transactional `Cartulary.Operations.PipelineRun.for_trigger` action, and
  `execute` and `mark_failed` declare the run's own Account inside their
  transaction; the lane's own work still runs outside that transaction, so no
  job holds a database connection across its workflow. No route, parameter,
  response field, or contract identity changes.
- Every authenticated API request returned `500 Internal Server Error` once the
  database role became one that row-level security actually applies to.
  `Cartulary.Operations.Metering.record_api/2` writes the edge usage-ledger row
  from `CartularyWeb.Plugs.MeterUsage`'s before-send callback, which runs after
  the request's own transactions have already ended, and it wrote that row with
  no Account declared to the database at all. The ledger's Account policy
  compares each new row against the transaction-local Account setting, so with
  none installed the insert was refused with `42501 insufficient_privilege` and
  the response the controller had already produced was replaced by a `500` —
  `/api/v1/ingest`, `/api/v1/search`, and every other metered route alike. The
  same omission on the read side made `Cartulary.Operations.Metering.summary/1`
  fail silently instead: `GET /api/v1/costs` and the console's overview and
  operations pages reported an Account with real recorded spend as having
  consumed nothing, because the policy filtered the whole ledger away rather
  than raising. Both entry points now open their own
  `Cartulary.DataLayer.in_account_transaction/2`, which is also what keeps the
  ledger row independent of whether the request's own work committed. No route,
  parameter, response field, or contract identity changes; the `f10-1` stamp on
  edge rows is unchanged.
- The two background rebuild lanes left out of the previous fix now follow the
  same rule: `Cartulary.Retrieval.Indexer.rebuild_scope/2` and
  `Cartulary.Retrieval.EntityResolver.rebuild_scope/2` no longer hold an
  Account database transaction across a model call. Both previously opened one
  `Cartulary.DataLayer.with_account_id/3` transaction around the entire scope
  rebuild with provider calls inside it — one batched embedding call for the
  indexer, and for the entity resolver, one embedding call per unmatched
  surface form plus one `dream_reasoner` structured-adjudication call per
  ambiguous surface form, so a scope with any real number of proper nouns
  comfortably exceeded DBConnection's 15 000 ms checkout-ownership timeout and
  lost its connection mid-rebuild, discarding writes for provider calls that
  had already run and already been billed. Each now reads in one short
  transaction, resolves with no transaction open, and writes everything
  durable in one final short transaction; the entity resolver resolves against
  an in-memory working set seeded from that read rather than re-reading the
  Account's entities per surface form, and keeps clearing a scope's stale
  mentions and writing its rebuilt ones in that same final transaction, so a
  failure anywhere still leaves the previous index in place rather than half
  cleared. Fixes a latent bug in `Cartulary.Retrieval.Vector.cosine/2`
  surfaced by the regression tests for this change: it multiplied and divided
  `Nx.Tensor` values with Kernel operators instead of `Nx.multiply/2` and
  `Nx.divide/2`, which always raised once an account actually had more than
  one entity to compare a surface form's embedding against — the entity
  resolver's fuzzy-match tier had never run successfully outside a fresh
  scope's very first surface form. Rebuild ordering, upsert-on-conflict entity
  convergence, mention-visibility inheritance, and the `f7-1` contract
  identity are unchanged.
- No external model call runs inside an Account database transaction any
  more. Extraction previously held one pooled PostgreSQL connection across the
  whole pipeline, including up to three sequential provider calls (one plus
  two bounded repairs) at up to `CARTULARY_MODEL_RECEIVE_TIMEOUT_MS` — 120
  seconds — each. DBConnection closes a connection whose checkout exceeds its
  ownership timeout, 15 000 ms by default and not overridden for
  `Cartulary.Repo`, so any extraction whose cumulative provider time crossed
  roughly 15 seconds lost its connection mid-transaction. The write recording
  an already-completed, already-billed call was discarded and the job retried,
  charging the Account a second time; observed at scale as roughly one in 25
  first attempts against a reasoning model. Raising `POOL_SIZE` does not help,
  because the failure is one connection held too long rather than too few
  connections. Three call sites are affected:
  `Cartulary.Memory.extract_message/2` and
  `Cartulary.Memory.extract_message_for_account/2`,
  `Cartulary.Documents.Service.process_version_for_account/2` (whose
  transaction also spanned the blob fetch, the parse, and the embedding call),
  and both provider calls on the `/api/ask` request path — the rerank step in
  `Cartulary.Retrieval.Engine` and grounded answer generation in
  `Cartulary.Memory`, each of which wrapped its call in a transaction that
  existed only to scope the model layer. Each now reads in one short
  transaction, calls the model holding no connection, and writes in a second
  short transaction where it writes at all.
  `Cartulary.Model.Config` and `Cartulary.Model.Usage` scope their own
  Account-scoped reads and writes through the new
  `Cartulary.DataLayer.in_account_transaction/2`, since role resolution and
  usage metering both run during a provider call. A consequence: a usage record
  now commits independently, so a caller whose own write fails afterwards no
  longer rolls back the ledger row for a call that really was billed.
  Extraction ordering, idempotency, advisory locking, gate outcomes, provenance,
  and the `f5-1`, `f7-1`, and `poc-0` contract identities are unchanged.
- PostgreSQL row-level security — the database-enforced half of cross-Account
  isolation described in `AGENTS.md` as "two independent locks on the same
  door" — was inert in every deployment mode and every test lane, because
  PostgreSQL exempts superusers from RLS unconditionally and `FORCE ROW LEVEL
  SECURITY` only removes the table owner's exemption, never the superuser's.
  Every connection Cartulary made was a superuser connection: `postgres` in
  `mix test` and every CI lane, and — the deployment-affecting case — the
  bootstrap role pg0's `initdb` creates in the turnkey single-node install.
  This did not leak tenant data; the Ash actor and tenant filter still ran on
  every query and were the layer actually enforcing isolation. It meant the
  documented backstop for a missed application-layer filter was not there,
  and no test could detect its absence. Every deployment mode now provisions
  and connects as a `NOSUPERUSER NOBYPASSRLS` role
  (`Cartulary.Database.AppRole`), and refuses to boot if that switch did not
  take unless `CARTULARY_ALLOW_UNRESTRICTED_DATABASE_ROLE=true` is set. See
  `specs/adr/0008-restricted-database-role-for-rls-enforcement.md` and
  GitHub issue #55.
- A job that failed once and was scheduled for a delayed retry (state
  `retryable`) stayed in that state permanently instead of running again once
  its backoff elapsed. `config :cartulary, Oban` sets `plugins: false`, and
  `AshOban.config/2` treats any `:plugins` value that is not already a
  non-empty list as "also disable peer leadership entirely" by forcing
  `peer: false`, which Oban resolves to a peer that can never become leader.
  Oban's job stager only promotes delayed `scheduled`/`retryable` jobs back to
  `available` while its node holds leadership, so every node was permanently
  unable to stage its own retries — silently, with no exception raised.
  `Cartulary.Application.oban_config/0` now restores the ordinary
  database-backed peer after `AshOban.config/2` runs, so this node can win
  leadership again; every other consequence of the empty plugin list (no
  Cron, no Pruner) is unchanged.
- Generation roles (`ingest_extractor`, `dream_reasoner`, `dialectic_agent`)
  now default to a bounded reasoning-token spend, an 8192 output-token cap,
  and a 120-second request timeout, overridable with
  `CARTULARY_MODEL_REASONING_EFFORT`, `CARTULARY_MODEL_MAX_TOKENS`, and
  `CARTULARY_MODEL_RECEIVE_TIMEOUT_MS` respectively. Without them, a
  reasoning model such as the default `openai/gpt-oss-120b` could spend an
  uncapped share of its context window on internal reasoning tokens
  regardless of input size — observed in practice as a single-sentence
  ingest extraction with ~600 input/tool tokens requesting roughly 131k
  output tokens and failing once it exceeded the model's whole
  131072-token context window — and, separately, could exceed ReqLLM's
  plain 30-second default request timeout, because ReqLLM only extends its
  timeout for model ids it recognizes as reasoning models (OpenAI's
  o-series, gpt-5, and codex families), which `gpt-oss-120b` does not match.
  `max_tokens` and `receive_timeout` request options already existed in
  `Cartulary.Model.Providers.ReqLLM`; `reasoning_effort` was added to its
  allowlist, and all three now have a default. Role options are always
  string-valued, but req_llm validates `reasoning_effort` against a fixed
  atom enum and rejects a string outright — every extraction call failed
  immediately on this option until `Cartulary.Model.Providers.ReqLLM` started
  converting it to the atom the schema requires.

### Added

- Entity-resolution quality is now observable without making the private
  entity cache public. The account-admin operations page reports entity and
  mention counts, observed-alias buckets, singleton-entity rate, and
  mentions-per-entity p50/p95. Statement detail reports and links only the
  other statements that share an entity and pass the reader's scope,
  lifecycle, soft-delete, and provisional-subject filters. The reviewed
  read-only store returns aggregates or authorized statement ids only; entity
  ids, canonical names, aliases, and surface forms remain pipeline-internal.
  No route or contract identity changed.
- Scope index coverage, so a scope that holds every governed statement and no
  embeddings is finally visible. Embeddings and entity mentions are written by
  the projection refresh alone; a refresh that was cancelled or never enqueued
  left semantic and entity recall permanently empty while full-text search kept
  answering — its index is a generated column no queue failure can lose — and
  nothing anywhere reported the gap. `Cartulary.Retrieval.index_coverage/3`
  returns per-scope statement, embedded, and entity-mention counts plus the
  embedding identities in use, filtered by Account and authorized scopes and
  narrowing provisional statements to their subject like every other retrieval
  query. Mentions are reported as a count, so the entity cache stays internal.
  `/console/scopes` shows the counts and highlights a shortfall, and every
  completed refresh emits `[:cartulary, :retrieval, :projection_refresh]` with
  `indexed`, `statements`, `embedded`, `mentions`, and `coverage` so an
  operator can alert on the ratio. No new table, route, or contract identity.
- Two off-by-default switches let an operator declare an Account or a whole
  deployment has no real human governance participant, and auto-grant the
  subject-consent step `Cartulary.Governance.Engine` otherwise blocks on for
  personal knowledge above peer level: `Account.consent_mode: "auto"`
  (account-admin only, audited) and `CARTULARY_GOVERNANCE_UNATTENDED=true`
  (boot-time, logged, reported on `GET /api/ready`). Intended for benchmark,
  evaluation, and synthetic-data deployments that have no real subject who
  could ever grant consent themselves. Also fixes a structural gap where the
  ordinary (non-promotion) ingestion path could never open a consent request
  at all, for a real subject or a declared-auto one. See
  `specs/adr/0007-unattended-governance-consent.md`.
- A browser console at `/console`, open to every human role. It carries an
  overview dashboard scoped to the reader's grants, a knowledge explorer with
  attribute filters and a side-by-side retrieval preview reporting contributed
  and dropped strategies, a per-statement page showing provenance, extraction
  and embedding identity, lifecycle timeline, gate decisions, relations, and
  the raw observations and document versions behind the claim, a scope
  directory, a deterministic server-rendered SVG graph of scopes and
  statements, a sources page, a skill card library with a self readiness check,
  a personal self-governance page, and an account-admin operations page.
  Curator decisions, promotion requests, and subject verdicts are dispatched to
  the existing operation layer; the console performs no durable write of its
  own and exposes no entity row, vector, chunk, or secret.
  `CartularyWeb.Console.Access` holds its two visibility rules — a
  `provisional` statement is visible only to its subject, and undecided or
  withdrawn states are curator-only except about oneself. New surface entry
  `browser_console` in `specs/eval/surface-contract-inventory.json`, gated by
  `test/cartulary_web/live/console_live_test.exs`,
  `test/cartulary_web/console/access_test.exs`, and
  `test/cartulary_web/console/graph_test.exs`. Design note:
  `specs/architecture/browser-console.md`; guide:
  `docs/guides/web-console.md`. No contract version identity changed.
- A general browser sign-in at `/sign-in` admitting any human password
  identity, plus `/sign-out` and a redirect from the bare origin to
  `/console`. It writes the same session key the curator sign-in uses, so one
  sign-in opens whichever surface the reader's role allows.
- A `docs/`, `README.md`, and `AGENTS.md` obligation binding browser-console
  changes to their documentation: a new row in the `AGENTS.md` change table and
  a "Browser console" discipline section covering the visibility rules,
  operation-layer-only writes, entity non-exposure, and the no-bundler and
  no-inline-script constraints on new controls.

- A published user documentation site built with MkDocs Material from `docs/`
  and deployed to GitHub Pages by `.github/workflows/docs.yml`. The site covers
  installation, a quickstart, how the system works (memory model, ingest
  pipeline, governance gates, retrieval and context, documents and connectors,
  skill readiness, isolation and access control, deployment modes),
  task-oriented guides, operations runbooks, and a reference section (HTTP API,
  configuration, Mix tasks, contract versions, glossary, limitations). Diagrams
  are Mermaid and render natively. The build runs with `strict: true`, so an
  orphaned page or a broken internal link fails CI. Enabling GitHub Pages with
  "GitHub Actions" as its source remains a maintainer-owned repository setting.
- A "Documentation layout" section in `AGENTS.md` and a "Where documentation
  goes" section in `CONTRIBUTING.md` making the two-tree split a contract, with
  a table mapping each kind of change to the document it must update in the
  same patch, plus a matching review question.

### Changed

- A retrieval strategy that could not run is now reported in
  `dropped_strategies` rather than as a contributing strategy that found
  nothing. `search` with a failed embedder previously returned an empty
  `semantic` result, which reads identically to a query with no near
  neighbours; the two call for opposite responses. Strategies may now return
  `{:error, reason}` from `candidates/2`, which the engine reports as
  degradation — matching how it already treats a deadline kill and a reranker
  failure. Response fields are unchanged; `semantic` simply now appears in
  `dropped_strategies` where it previously appeared in
  `contributed_strategies`.
- The curator queue at `/governance` now renders inside the shared console
  frame and takes its appearance from `priv/static/assets/console.css` instead
  of inline styles. Its route, module, events, decisions, and rendered heading
  are unchanged, so the curator-surface and skill-card regression evidence
  still holds. Curators reach it from the console navigation, and individual
  decisions can now also be taken from a statement's own page, where the
  evidence sits beside the controls.
- The browser pipeline now fetches the live flash, so a LiveView that reports a
  refusal while still rendering statically redirects instead of raising.
- Separated the documentation trees. `docs/` now holds only setup, usage, and
  operations documentation for readers of the published site; every
  design-facing document moved to `specs/`: `docs/adr/` → `specs/adr/`,
  `docs/architecture/` → `specs/architecture/`, `docs/roadmap/` →
  `specs/roadmap/`, `docs/eval/` → `specs/eval/`, `docs/security/` →
  `specs/security/`, `docs/observability/` → `specs/observability/`,
  `docs/implementation-status.md` → `specs/implementation-status.md`,
  `docs/superpowers/specs/` → `specs/design/`, and the versioning policy and
  release checklist from `docs/operations/` → `specs/process/`. File names are
  unchanged, so the recorded evaluation reports and every other evidence
  artifact keep their identities. References were updated in
  `Cartulary.ReleaseReadiness`, `mix cartulary.eval.release`, the evaluation
  regression test, `.github/CODEOWNERS`, the issue and pull request templates,
  the workflows README, `AGENTS.md`, `CONTRIBUTING.md`, and `README.md`.
- Replaced `docs/operations/README.md` with the new operations section and the
  getting-started install pages; `backup-restore.md` and `portability.md` stay
  under `docs/operations/` as operator-facing runbooks.
- Rewrote the `README.md` documentation map around the two trees and linked the
  published site from the header, the quick start, the operations section, and
  the observability section.
- Removed the retired `F5`, `F6`, and `F10` phase labels from `.env.example`
  comments.

- Made every first-party source file self-explanatory. Each module now carries
  a real `@moduledoc` stating what it owns, the invariants it guarantees, and
  the mistakes callers must avoid; public functions document their return shape
  and failure modes; comments explain why rather than restating code; and
  configuration, packaging, CI, and script files carry header comments naming
  purpose, inputs, outputs, and assumptions. No behaviour changed.
- Removed every pointer from source comments into `specs/` and `docs/`, and
  every remaining `F0`–`F11` phase label from code prose, replacing each with
  the rule stated in place. The `f`-prefixed contract identity values
  (`poc-0`, `f4-1`, `f5-1`, `f7-1`, `f9-1`, `f10-1`, `f11-1`, `f11-suite-1`,
  `f11-surface-contracts-1`, `cartulary-account-1`) are unchanged, and the test
  filenames that carry regression-evidence identities were deliberately not
  renamed.
- Added a "Coding conventions" section to `AGENTS.md` making the above a
  contract, with matching review questions, a `CONTRIBUTING.md` rewrite, and a
  self-explanatory-code checklist in the pull request template.
- Expanded `README.md` with a core-concepts glossary, an end-to-end walkthrough
  of an ingest request, a repository layout table, and a guided reading order.
- Corrected stale `blueprint/` paths to `specs/` in `CONTRIBUTING.md`,
  `.github/CODEOWNERS`, the pull request template, and the three issue
  templates.
- Replaced the boilerplate `priv/repo/seeds.exs` comment, which advised writing
  through `Cartulary.Repo.insert!/1` and so contradicted the pipeline-only and
  Ash-action-only write rules.
- Updated the official GitHub Actions used by CI, nightly evaluation, and
  release workflows to maintained Node 24 action majors.
- Retired the `F0`–`F11` roadmap phase labels from all documentation in favour
  of literal capability names, and removed proof-of-concept framing now that
  the project is a community beta. The `f`-prefixed contract identities
  (`f4-1`, `f5-1`, `f7-1`, `f9-1`, `f10-1`, `f11-1`, `f11-suite-1`,
  `f11-surface-contracts-1`) and the historical `poc-0` baseline are unchanged;
  they are version tags, not phase labels, and are now documented as such in
  `AGENTS.md` and `docs/architecture/free-core-architecture.md`.
- Renamed each `docs/architecture/fN-*.md` note to its capability name and
  rewrote `README.md` and `AGENTS.md` around the same vocabulary. `CLAUDE.md`
  is now an import of `AGENTS.md` instead of a duplicate copy.
- Changed the `prerequisite` value for the unavailable OpenAPI and generated
  SDK surfaces in `docs/eval/surface-contract-inventory.json` from `F8` to
  `integration-surfaces`, with the matching assertion updated in
  `test/cartulary/f11_evaluation_ci_release_readiness_test.exs`. The
  `f11-surface-contracts-1` schema identity and the `unavailable` statuses are
  unchanged.

### Added

- `docs/roadmap/beta-roadmap.md` as the single roadmap. It merges
  `l3-automation-flow.md`, `main-branch-ruleset.md`, and
  `manual-automation-setup.md`, absorbs the still-open phases of
  `free-core-roadmap.md`, records the verified GitHub configuration as of
  2026-07-28, and tracks every remaining item as a checkbox
  (`AD-EVAL-2`, `AINV-1`).

### Removed

- `docs/roadmap/l3-automation-flow.md`, `docs/roadmap/main-branch-ruleset.md`,
  and `docs/roadmap/manual-automation-setup.md`. Their still-relevant content
  is in `docs/roadmap/beta-roadmap.md`; the steps already completed in GitHub
  are recorded there as verified rather than repeated as instructions.
- `docs/roadmap/free-core-roadmap.md`. Its durable architecture content moved
  to `docs/architecture/free-core-architecture.md`; its completed phases are
  now history in `docs/implementation-status.md` (formerly
  `docs/poc-local-proof.md`).

## [0.2.1] - 2026-07-29

### Fixed

- Ingest extraction no longer fails validation with `confidence must be
  between 0 and 1` when a provider's structured tool-call output round-trips
  the `confidence` field as a JSON string instead of a native number —
  observed identically across unrelated backing models over the OpenRouter
  compat path, which pointed at a type problem rather than a range problem.
  `Cartulary.Model.Schema.Extraction`'s `confidence/1` validator now parses a
  numeric string before range-checking it; the 0–1 range check itself, for
  both numbers and numeric strings, is unchanged. No contract version
  identity changed. Regression evidence:
  `test/cartulary/model/schema_extraction_test.exs`.

## [0.2.0] - 2026-07-28

### Added

- F11 deterministic release guardrails for formatting, warnings-as-errors
  compilation, Ash snapshot drift, tests and properties, Credo, Dialyzer,
  Sobelow, surface privacy, provider cassettes, and evaluation report
  provenance (`AD-EVAL-1` through `AD-EVAL-5`, `AD-DATA-10`).
- Versioned `f11-1` release/nightly evaluation reports for Cartulary product
  scenarios, LoCoMo, LongMemEval, ConvoMem, and BEAM, including deterministic
  RAG-triad signals, abstention/citation measures, token efficiency, latency,
  per-category scores, degradation curves, and strategy ablations
  (`AD-EVAL-3`, `NFR-1`, `NFR-11`).
- External-Postgres and packaged pg0 CI lanes, release and container builds,
  scheduled evals, semantic-version/tag validation, and a fail-closed release
  checklist (`AD-EVAL-2`, `FR-PLAT-2`, `FR-PLAT-4`, `FR-PLAT-5`).

### Changed

- Replaced the obsolete SQLite CI placeholder with the Postgres-only parity
  model selected by ADR-0003.
- Advanced the application version from `0.1.0` to `0.2.0`. Retrieval remains
  profile contract `f7-1`; F11 versions evaluation evidence and release policy,
  not product retrieval behavior.
- Made the governance LiveView bootstrap asset part of the tracked release
  source so clean CI checkouts and packaged builds exercise the same curator
  surface as developer worktrees.

## [0.1.0] - 2026-07-28

### Added

- Initial Cartulary POC and free-core implementation through F10, including the
  F0 contract, F1–F7, F9, and F10 evidence described in the roadmap.
