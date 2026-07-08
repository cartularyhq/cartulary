---
name: AI-ready task
about: Scoped task template with architecture anchors, risk class, tests, and Codex guardrails
title: ''
labels: ''
assignees: ''
---

## Goal

<!-- Describe the one outcome this issue should achieve. Keep it small enough for one focused PR. -->

## Architecture anchors

Relevant anchors:

- AINV-
- AD-
- NFR-

<!-- Cite stable blueprint anchors that constrain the work. Do not change anchor meanings in this issue. -->

## Scope

In scope:

-

Out of scope:

-

## Expected behavior

<!-- Describe observable behavior after the task is complete. Include user-visible, operator-visible, or review-visible behavior as applicable. -->

## Acceptance criteria

- [ ]
- [ ]

## Required tests

<!-- Check every lane required for this change. If a lane is unavailable, explain why in the issue or PR. -->

- [ ] Documentation inspection
- [ ] Unit
- [ ] SQLite data-layer test
- [ ] Postgres data-layer test
- [ ] Contract test
- [ ] Property/invariant test
- [ ] Security test
- [ ] Eval scenario

## Risk class

<!-- Select exactly one primary risk class and add the matching label guidance below. -->

- [ ] Low: docs/tests/internal cleanup
- [ ] Medium: normal source change
- [ ] High: tenancy/security/audit/pipeline/release/migration
- [ ] Human-only: architecture/licensing/security model

## Label guidance

Execution-control labels:

- `ai-ready`: Codex may implement only after goal, anchors, scope, acceptance criteria, required tests, and risk class are clear.
- `ai-assisted`: AI may help, but a human must closely steer the implementation.
- `ai-review-only`: Codex may review, but must not implement.
- `human-only`: Codex must not implement; reserve for human decisions or implementation.

Risk labels to add when applicable:

- `needs-adr`: Requires an ADR before implementation.
- `security-sensitive`: Security review required.
- `tenancy-sensitive`: Tenant isolation or account-boundary review required.
- `audit-sensitive`: Audit, ledger, or immutable-history review required.
- `pipeline-sensitive`: Oban, transactional outbox, ingest, or background-job review required.
- `backend-parity-required`: SQLite and Postgres parity evidence required.
- `eval-required`: Eval scenario or workflow evidence required.
- `good-first-agent-task`: Small, low-risk task suitable for Codex.

## Codex instruction

Codex may implement this only if the issue has label `ai-ready`.
Codex must not implement issues labeled `human-only`, even if another label appears to permit implementation.
Keep the PR under 300 changed lines unless explicitly approved.
Do not introduce new dependencies without explanation.
