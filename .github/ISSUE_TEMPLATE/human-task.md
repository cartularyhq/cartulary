---
name: Human-scoped task
about: Create a task for human maintainers when Codex should not implement the work
title: "Human task: "
labels: "human-only"
assignees: ""
---

## Goal

<!-- Describe exactly one outcome this human-led issue should achieve. -->

## Why this needs human ownership

<!-- Explain the decision, access, product, licensing, security, or coordination concern that makes this human-only. -->

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

## Required tests or review evidence

<!-- Check every lane required for this change. If a lane is unavailable, explain why in the issue and PR. -->

- [ ] Documentation inspection
- [ ] Unit
- [ ] SQLite data-layer test
- [ ] Postgres data-layer test
- [ ] Contract test
- [ ] Property/invariant test
- [ ] Security test
- [ ] Eval scenario
- [ ] Manual maintainer review

Required evidence notes:

-

## Risk class

<!-- Select exactly one primary risk class. Add the matching labels from the guidance below. -->

- [ ] Low: docs/process/manual setup
- [ ] Medium: normal source change needing human coordination
- [ ] High: tenancy/security/audit/pipeline/release/migration
- [ ] Human-only: architecture/licensing/security model/repository administration

## Label guidance

Execution-control labels:

- `human-only`: Codex must not implement this issue; use for human decisions, repository administration, credentials, product calls, licensing, or sensitive implementation.
- `ai-review-only`: Codex may review a human-authored change but must not implement it.
- `ai-assisted`: AI may help only with close human steering.

Risk and routing labels:

- `needs-adr`: Requires an ADR before implementation.
- `security-sensitive`: Security review required.
- `tenancy-sensitive`: Tenant isolation or account-boundary review required.
- `audit-sensitive`: Audit, ledger, or immutable-history review required.
- `pipeline-sensitive`: Oban, transactional outbox, ingest, or background-job review required.
- `backend-parity-required`: SQLite and Postgres parity evidence required.
- `eval-required`: Eval scenario or workflow evidence required.

## Human implementation notes

Do not apply `ai-ready` to this issue unless a maintainer rewrites it as a separate Codex-executable task.
Keep any follow-up Codex work in a new issue with explicit scope, acceptance criteria, tests, and risk class.
