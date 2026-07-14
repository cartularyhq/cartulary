---
name: AI-ready task
about: Create a small, bounded, testable task that Codex may implement after ai-ready is applied
title: "Task: "
labels: ""
assignees: ""
---

## Goal

<!-- Describe exactly one outcome this issue should achieve. Keep it small enough for one focused PR. -->

## Reference docs

<!-- Link the internal docs that provide the task context reviewers and implementers should read. Include the closest specific document(s), not every possible doc. Delete rows that do not apply. -->

- Blueprint requirements: `blueprint/memory-system-functional-requirements.md` (`FR-*` anchors):
- Blueprint architecture/NFRs: `blueprint/memory-system-architecture-and-nfr.md` (`AD-*`, `AINV-*`, `NFR-*` anchors):
- Product context: `blueprint/memory-system-product-blueprint.md`:
- ADRs: `docs/adr/README.md` or `docs/adr/<adr-file>.md`:
- Architecture notes: `docs/architecture/README.md` or `docs/architecture/<note>.md`:
- Roadmap/process docs: `docs/roadmap/l3-automation-flow.md`, `docs/roadmap/manual-automation-setup.md`, or `docs/roadmap/main-branch-ruleset.md`:
- Security/eval docs: `docs/security/README.md`, `docs/eval/README.md`, or a specific note:
- Other internal docs:

## Architecture anchors

<!-- Cite stable blueprint anchors that constrain the work. Do not change anchor meanings in this issue. -->

Relevant anchors:

- AINV-
- AD-
- FR-
- NFR-

## Scope

In scope:

-

Out of scope:

-

## Expected behavior

<!-- Describe the observable behavior after completion. Include user-visible, operator-visible, API-visible, or review-visible behavior as applicable. -->

## Acceptance criteria

<!-- Make each item independently reviewable. -->

- [ ]
- [ ]

## Required tests

<!-- Check every lane required for this change. If a lane is unavailable, explain why in the issue and PR. -->

- [ ] Documentation inspection
- [ ] Unit
- [ ] SQLite data-layer test
- [ ] Postgres data-layer test
- [ ] Contract test
- [ ] Property/invariant test
- [ ] Security test
- [ ] Eval scenario

Required evidence notes:

-

## Risk class

<!-- Select exactly one primary risk class. Add the matching labels from the guidance below. -->

- [ ] Low: docs/tests/internal cleanup
- [ ] Medium: normal source change
- [ ] High: tenancy/security/audit/pipeline/release/migration
- [ ] Human-only: architecture/licensing/security model

## Label guidance

Execution-control labels:

- `ai-ready`: Codex may implement only after the goal, architecture anchors, scope, expected behavior, acceptance criteria, required tests, and risk class are clear.
- `ai-assisted`: AI may help, but a human must closely steer the implementation.
- `ai-review-only`: Codex may review, but must not implement.
- `human-only`: Codex must not implement; reserve for human decisions or implementation.

Risk and routing labels:

- `needs-adr`: Requires an ADR before implementation.
- `security-sensitive`: Security review required.
- `tenancy-sensitive`: Tenant isolation or account-boundary review required.
- `audit-sensitive`: Audit, ledger, or immutable-history review required.
- `pipeline-sensitive`: Oban, transactional outbox, ingest, or background-job review required.
- `backend-parity-required`: SQLite and Postgres parity evidence required.
- `eval-required`: Eval scenario or workflow evidence required.
- `good-first-agent-task`: Small, low-risk task suitable for Codex.

## Codex instruction

Codex may implement this issue only if the `ai-ready` label is applied.
Codex must not implement this issue if `human-only` is applied, even if another label appears to permit implementation.
Codex must implement only the in-scope acceptance criteria and must not batch unrelated tasks into the PR.
Codex must report real check evidence in the PR and final response; unavailable checks must be called out explicitly.
Do not introduce new dependencies without explanation.
