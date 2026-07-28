<!-- SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0 -->

# Changelog

All notable Cartulary changes are recorded here. Versions follow Semantic
Versioning. While the public API is pre-1.0, a minor release may intentionally
version an incomplete surface; breaking changes still require an explicit
changelog entry and contract-version transition.

## [Unreleased]

### Changed

- Nothing yet.

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
