<!-- SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0 -->

# Changelog

All notable Cartulary changes are recorded here. Versions follow Semantic
Versioning. While the public API is pre-1.0, a minor release may intentionally
version an incomplete surface; breaking changes still require an explicit
changelog entry and contract-version transition.

## [Unreleased]

### Changed

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
