<!-- SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0 -->

# Changelog

All notable Cartulary changes are recorded here. Versions follow Semantic
Versioning. While the public API is pre-1.0, a minor release may intentionally
version an incomplete surface; breaking changes still require an explicit
changelog entry and contract-version transition.

## [Unreleased]

### Fixed

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
