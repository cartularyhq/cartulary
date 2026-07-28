<!-- SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0 -->

# F11 Evaluation, CI, And Release Readiness

Status: implemented on 2026-07-28.

F11 turns the F0–F10 evidence into blocking automation and reproducible release
reports without changing the 38-Resource durable boundary. It implements
`AD-EVAL-1` through `AD-EVAL-5`, `NFR-1`, `NFR-11`, and the evaluation
framework's `EV-*` contracts. Retrieval remains `f7-1`; evaluation evidence is
versioned `f11-1`, and the application advances to semantic version `0.2.0`.

## Deterministic gate

The external-Postgres CI lane runs Ash snapshot drift, formatting,
warnings-as-errors compilation, the complete ExUnit/property suite, Credo,
Sobelow, Hex retirement audit, and the deterministic release matrix. Dialyzer
has a cached dedicated lane. Existing F1–F10 tests supply the data-layer,
strategy, Account isolation, consent/promotion, cassette, MCP/HTTP/readiness
helper, and no-public-entity guardrails; the focused F11 test prevents the CI,
version, surface inventory, and release contracts from drifting.

The packaged-pg0 lane assembles the checksum-pinned release, boots it from an
empty temporary data root, waits for `f10-1` readiness, and runs the same
complete source test suite against a separate database in that pg0 instance.
The build job runs only after external Postgres, pg0, and Dialyzer pass, then
builds both the Mix release and production container.

F8 has not supplied AshJsonApi OpenAPI or complete generated TypeScript/Python
clients. F11 does not invent those surfaces. The machine-readable surface
inventory marks them `unavailable`, gates the shipped Phoenix/MCP/F9 helper
contracts, and prevents 0.2.0 documentation or packaging from presenting the
F9 helpers as complete SDKs.

## Evaluation boundary

`Cartulary.Eval.Adapter` now supports Cartulary, LoCoMo, LongMemEval, ConvoMem,
and BEAM source shapes. Every input carries a SHA-256. `Runner` records the
application version, date, dataset id/hash/split, profile and exact version,
strategy override, deadline setting, four model-role identities, judge method,
limits, and per-question evidence.

`Scorer` retains deterministic correctness, abstention, and citation measures
and adds lexical `f11-1` groundedness/context-relevance/answer-relevance plus
context, answer, end-to-end, full-context, and efficiency-ratio token measures.
Those lexical scores are reproducible baseline signals, not a claim of parity
with an upstream model judge.

`docs/eval/release-suite.json` defines the release matrix and distinct
`held-out-tuning`/`release-evaluation` policy. Named-profile runs are release
guardrails; lexical and salience-recency variants are reported ablations.
`deterministic-thresholds.json` gates only correctness and citations. Quality,
latency, RAG-triad, token efficiency, and BEAM degradation remain
frontier-tracked as required by `AD-EVAL-3`, `NFR-1`, and `NFR-11`.

The 2026-07-27 minimal `poc-0` reports remain immutable Stage 0 evidence from
before F7. They are not silently relabeled as current `f7-1` results.

## Release controls

Cartulary follows Semantic Versioning with a Keep-a-Changelog-style
`CHANGELOG.md`. `mix cartulary.release.check` fails unless:

- `mix.exs` contains valid SemVer and a matching dated changelog entry;
- the tag, when supplied, is exactly `v<version>`;
- F11 roadmap, README, AGENTS, and architecture evidence agree;
- a non-empty `f11-suite-1` report matches the application version; and
- every deterministic release threshold still passes.

CI builds on every pull request and `main` push. The nightly workflow retains
eval artifacts for comparison. A semantic tag repeats deterministic guardrails,
validates the tag/eval/changelog tuple, builds the checksum-pinned Linux pg0
package and container, and uploads release/eval artifacts. Repository branch
protection and required-check selection remain GitHub settings performed by a
maintainer; the required job names are documented in the release checklist.

## Evidence

- `test/cartulary/f11_evaluation_ci_release_readiness_test.exs`
- `test/cartulary/eval/adapter_test.exs`
- `test/cartulary/eval/scorer_test.exs`
- `.github/workflows/ci.yml`
- `.github/workflows/eval.yml`
- `.github/workflows/release.yml`
- `docs/eval/release-suite.json`
- `docs/eval/deterministic-thresholds.json`
- `docs/eval/surface-contract-inventory.json`
- `docs/operations/release-checklist.md`
- `docs/operations/versioning.md`
