# Practical task handoff issues

This file contains ready-to-create GitHub issue bodies for Practical Tasks 3-30.
It exists because issue creation requires repository access from a human-owned or
automation-owned GitHub identity.

Use these tasks after Task 2 (`AGENTS.md`) is merged. Keep the L3 discipline:
**one task, one issue, one branch, one PR, human review, then the next task**.

## How to create these as GitHub issues

### Option A: GitHub UI

1. Open the repository on GitHub.
2. Go to **Issues** -> **New issue**.
3. Choose the standard task template.
4. Copy one task below into the issue body.
5. Add the recommended labels.
6. Create the issue.
7. Repeat only for the next few tasks you are ready to supervise.

### Option B: GitHub CLI

From a maintainer machine with `gh` installed and authenticated:

```bash
gh issue create \
  --title "Task 3: Add CONTRIBUTING.md" \
  --label "good-first-agent-task" \
  --label "ai-ready" \
  --body-file /path/to/task-03.md
```

Do not bulk-label later implementation tasks `ai-ready` until their acceptance
criteria, risk, and required tests have been reviewed.

## Recommended issue sequencing

Create issues in small batches:

- Batch A: Tasks 3-8, repository governance and contributor process.
- Batch B: Tasks 9-18, CI lanes and merge-group trigger.
- Batch C: Tasks 19-23, Codex review prompts and ADRs.
- Batch D: Tasks 24-30, Mix/Phoenix skeleton and single-node packaging.

Only the next task should be assigned to Codex for implementation. Later tasks
can exist as backlog issues but should not be marked `ai-ready` until reviewed.

---

## Task 3: Add CONTRIBUTING.md

Recommended labels: `good-first-agent-task`, `ai-ready`

```md
## Goal

Add a top-level `CONTRIBUTING.md` that explains how humans and Codex contribute
to Cartulary under the L3 automation flow.

## Architecture anchors

Relevant anchors:
- AINV-1 one codebase, two deployment modes, identical guarantees
- AINV-6 account is derived from identity, never request params
- AD-TOPO-1 Mix umbrella or single app with clear boundaries

## Scope

In scope:
- Contribution workflow for one issue -> one branch -> one PR.
- Requirement to read `AGENTS.md` and relevant blueprint anchors.
- Commit/PR expectations, test evidence expectations, and review expectations.
- Guidance for when commands are not yet available before the Mix project exists.

Out of scope:
- Security disclosure policy.
- CODEOWNERS.
- Active CI configuration.
- License or governance model changes.

## Expected behavior

Contributors can understand how to prepare a focused PR and what evidence to
include before requesting review.

## Acceptance criteria

- [ ] `CONTRIBUTING.md` exists at the repo root.
- [ ] It references `AGENTS.md` as the operating contract.
- [ ] It explains the one-task/one-PR flow.
- [ ] It explains how to report unavailable checks honestly.
- [ ] It does not enable automation or introduce tooling.

## Required tests

- [ ] Documentation inspection.

## Risk class

- [x] Low: docs/tests/internal cleanup

## Codex instruction

Codex may implement this only if the issue has label `ai-ready`.
Keep the PR focused on `CONTRIBUTING.md` only.
```

## Task 4: Add SECURITY.md

Recommended labels: `security-sensitive`

```md
## Goal

Add a top-level `SECURITY.md` that defines Cartulary's security reporting and
initial security posture without claiming unsupported processes.

## Architecture anchors

Relevant anchors:
- AINV-2 user owns data and keys
- AINV-6 cross-account isolation is absolute
- AD-SEC-* security, identity, and tenancy decisions

## Scope

In scope:
- Supported versions placeholder appropriate for pre-release.
- Vulnerability reporting instructions with maintainer-provided contact placeholder.
- Safe handling expectations for secrets, model keys, restricted content, and PII.
- Statement that security-sensitive changes require human review.

Out of scope:
- Enabling GitHub private vulnerability reporting.
- Creating disclosure email aliases.
- Adding security scanning workflows.

## Expected behavior

The repo has an initial security policy that can be refined when the public
contact and supported release policy are finalized.

## Acceptance criteria

- [ ] `SECURITY.md` exists at the repo root.
- [ ] It identifies pre-release support status clearly.
- [ ] It includes a placeholder or documented need for the human maintainer to add a disclosure contact.
- [ ] It reiterates no secrets/PII logging and tenant isolation expectations.

## Required tests

- [ ] Documentation inspection.

## Risk class

- [x] High: tenancy/security/audit/pipeline/release/migration

## Codex instruction

Codex may draft this, but a human must provide or confirm the disclosure contact
before the policy is considered complete.
```

## Task 5: Add PR template

Recommended labels: `good-first-agent-task`, `ai-ready`

```md
## Goal

Add or update the pull request template so every PR explains scope, risk, AI
usage, backend parity, and test evidence.

## Architecture anchors

Relevant anchors:
- AINV-1 one codebase, two modes, identical guarantees
- AINV-6 account isolation
- AD-EVAL-* deterministic PR gate and eval separation

## Scope

In scope:
- `.github/PULL_REQUEST_TEMPLATE.md` or canonicalize existing template casing.
- Sections for summary, linked issue, architecture anchors, risk class, AI usage,
  test evidence, backend parity, security/tenancy/audit impact, migration impact,
  and release-note impact.

Out of scope:
- CODEOWNERS.
- CI workflows.
- GitHub settings changes.

## Expected behavior

New PRs prompt authors to provide the evidence reviewers need.

## Acceptance criteria

- [ ] PR template exists at the GitHub-recognized path.
- [ ] It includes architecture anchors and risk class sections.
- [ ] It includes test evidence and backend parity sections.
- [ ] It includes AI usage accountability.

## Required tests

- [ ] Documentation inspection.

## Risk class

- [x] Low: docs/tests/internal cleanup

## Codex instruction

Codex may implement this only if the issue has label `ai-ready`.
```

## Task 6: Add issue templates

Recommended labels: `good-first-agent-task`, `ai-ready`

```md
## Goal

Add or refine GitHub issue templates so Codex-executable tasks are small,
bounded, and testable.

## Architecture anchors

Relevant anchors:
- AINV-1 one codebase, two modes, identical guarantees
- AD-EVAL-* deterministic PR gate

## Scope

In scope:
- Ensure an AI-ready task template exists under `.github/ISSUE_TEMPLATE/`.
- Include goal, architecture anchors, scope, expected behavior, acceptance
  criteria, required tests, risk class, and Codex instruction sections.
- Add label guidance for `ai-ready`, `human-only`, and risk labels.

Out of scope:
- Creating GitHub labels through API/UI.
- Changing branch rulesets.

## Expected behavior

A human can create a well-scoped issue that Codex can execute without guessing.

## Acceptance criteria

- [ ] Issue template exists and renders as Markdown.
- [ ] Template includes all required sections.
- [ ] Template says Codex may implement only when `ai-ready` is applied.

## Required tests

- [ ] Documentation inspection.

## Risk class

- [x] Low: docs/tests/internal cleanup

## Codex instruction

Codex may implement this only if the issue has label `ai-ready`.
```

## Task 7: Add CODEOWNERS

Recommended labels: `human-only`, `security-sensitive`

```md
## Goal

Add `.github/CODEOWNERS` around Cartulary's risk boundaries so sensitive paths
request human review.

## Architecture anchors

Relevant anchors:
- AINV-6 cross-account isolation is absolute
- AD-SEC-* security, identity, and tenancy
- AD-PIPE-* pipeline and transactional outbox
- AD-GOV-* governance and audit

## Scope

In scope:
- CODEOWNERS entries for `.github/`, `AGENTS.md`, CODEOWNERS itself,
  architecture/ADR docs, future core security/tenancy/audit/ledger/pipeline paths,
  workflows, `mix.exs`, and `mix.lock`.
- Use the maintainer handle confirmed by the repository owner.

Out of scope:
- Enabling branch protection/rulesets.
- Creating teams.

## Expected behavior

Sensitive files request the intended human owner for review once GitHub settings
require CODEOWNER approval.

## Acceptance criteria

- [ ] `.github/CODEOWNERS` exists.
- [ ] It protects itself and workflow/configuration paths.
- [ ] It includes future sensitive Cartulary paths.
- [ ] Maintainer/team handles are confirmed by a human.

## Required tests

- [ ] Documentation inspection.
- [ ] Human verifies GitHub recognizes the CODEOWNERS entries.

## Risk class

- [x] High: tenancy/security/audit/pipeline/release/migration

## Codex instruction

Human confirmation is required for owner handles before merge.
```

## Task 8: Add initial GitHub ruleset

Recommended labels: `human-only`, `security-sensitive`

```md
## Goal

Document and, where possible, export the initial GitHub ruleset for `main`.

## Architecture anchors

Relevant anchors:
- AINV-1 one codebase, two modes, identical guarantees
- AD-EVAL-* deterministic PR gate

## Scope

In scope:
- Add a documentation file describing the intended `main` ruleset.
- Include required PR, required reviews, CODEOWNER review, required checks once CI
  exists, blocked force pushes, blocked deletions, and merge queue readiness.

Out of scope:
- Enabling the ruleset in GitHub unless the human maintainer does it manually.
- Requiring checks before CI jobs exist.

## Expected behavior

The repository owner has a concrete ruleset checklist to apply in GitHub.

## Acceptance criteria

- [ ] Ruleset documentation exists.
- [ ] It names checks as future placeholders until CI tasks land.
- [ ] It warns not to require checks before they report.
- [ ] Manual GitHub setup steps are clear.

## Required tests

- [ ] Documentation inspection.
- [ ] Human verifies GitHub settings after manual configuration.

## Risk class

- [x] High: tenancy/security/audit/pipeline/release/migration

## Codex instruction

Codex should not claim the GitHub-hosted ruleset is enabled unless verified by a
human with repository settings access.
```

## Task 9: Add CI: format

Recommended labels: `backend-parity-required`

```md
## Goal

Add the first CI workflow lane for formatting.

## Architecture anchors

Relevant anchors:
- AD-EVAL-* deterministic PR gate

## Scope

In scope:
- Add a GitHub Actions workflow with a `format` job.
- Trigger on `pull_request`, `push` to `main`, and `merge_group` if merge queue is planned.
- Set `permissions: contents: read`.
- Use a maintained BEAM setup action once Mix project details exist.
- Run `mix format --check-formatted`.

Out of scope:
- Compile, tests, Credo, Dialyzer, Sobelow, deps audit.
- Branch protection changes.

## Expected behavior

Pull requests run a deterministic formatting check once the Mix project exists.

## Acceptance criteria

- [ ] Workflow file exists.
- [ ] Workflow uses least-privilege permissions.
- [ ] Format job runs `mix format --check-formatted`.
- [ ] Job is not marked required until it has reported successfully.

## Required tests

- [ ] Workflow syntax inspection.
- [ ] `mix format --check-formatted` when `mix.exs` exists.

## Risk class

- [x] Medium: normal source change

## Codex instruction

Do not add unrelated CI lanes in this PR.
```

## Task 10: Add CI: compile warnings as errors

Recommended labels: `backend-parity-required`

```md
## Goal

Add a CI lane that compiles with warnings treated as errors.

## Architecture anchors

Relevant anchors:
- AD-EVAL-* deterministic PR gate

## Scope

In scope:
- Add or extend CI with a `compile` job.
- Run `mix deps.get` and `mix compile --warnings-as-errors`.
- Keep permissions read-only.

Out of scope:
- Formatting lane changes unless needed for shared setup.
- Tests or static analysis lanes.

## Expected behavior

PRs fail when Elixir compilation emits warnings.

## Acceptance criteria

- [ ] Compile job exists.
- [ ] Job runs on PR and merge_group if configured.
- [ ] Warnings are treated as errors.

## Required tests

- [ ] Workflow syntax inspection.
- [ ] `mix compile --warnings-as-errors` when project exists.

## Risk class

- [x] Medium: normal source change

## Codex instruction

Keep the PR limited to compile CI.
```

## Task 11: Add CI: unit tests

Recommended labels: `backend-parity-required`

```md
## Goal

Add a CI lane for the default unit test suite.

## Architecture anchors

Relevant anchors:
- AD-EVAL-* deterministic PR gate

## Scope

In scope:
- Add a `unit` or `test` job that runs `mix test`.
- Use read-only permissions.
- Keep DB-specific lanes separate for later tasks.

Out of scope:
- SQLite-only and Postgres-only lanes.
- Credo, Dialyzer, Sobelow, deps audit.

## Expected behavior

Default deterministic tests run on PRs.

## Acceptance criteria

- [ ] Unit test job exists.
- [ ] Job runs `mix test`.
- [ ] Job is separate from backend-specific lanes.

## Required tests

- [ ] Workflow syntax inspection.
- [ ] `mix test` when project exists.

## Risk class

- [x] Medium: normal source change

## Codex instruction

Keep the PR limited to the default unit test lane.
```

## Task 12: Add CI: Credo

Recommended labels: `backend-parity-required`

```md
## Goal

Add a CI lane for Credo strict static analysis.

## Architecture anchors

Relevant anchors:
- AD-EVAL-* deterministic PR gate

## Scope

In scope:
- Add Credo configuration/dependency only if not already present and justified.
- Add CI job running `mix credo --strict`.

Out of scope:
- Dialyzer, Sobelow, deps audit.

## Expected behavior

Static code quality issues fail the deterministic PR gate.

## Acceptance criteria

- [ ] Credo is configured when the Mix project exists.
- [ ] CI job runs `mix credo --strict`.
- [ ] Any new dependency is explained.

## Required tests

- [ ] `mix credo --strict` when project exists.

## Risk class

- [x] Medium: normal source change

## Codex instruction

Do not add unrelated static analysis tools in this PR.
```

## Task 13: Add CI: Dialyzer

Recommended labels: `backend-parity-required`

```md
## Goal

Add a CI lane for Dialyzer type analysis.

## Architecture anchors

Relevant anchors:
- AD-EVAL-* deterministic PR gate

## Scope

In scope:
- Add Dialyzer configuration/dependency only if not already present and justified.
- Add CI job running `mix dialyzer`.
- Consider PLT caching once the project exists.

Out of scope:
- Credo or Sobelow changes.

## Expected behavior

Dialyzer analysis is part of the deterministic PR gate.

## Acceptance criteria

- [ ] Dialyzer can run locally.
- [ ] CI job runs `mix dialyzer`.
- [ ] Caching is safe and does not hide failures.

## Required tests

- [ ] `mix dialyzer` when project exists.

## Risk class

- [x] Medium: normal source change

## Codex instruction

Keep this focused on Dialyzer only.
```

## Task 14: Add CI: Sobelow

Recommended labels: `security-sensitive`

```md
## Goal

Add a CI lane for Sobelow Phoenix security scanning.

## Architecture anchors

Relevant anchors:
- AINV-6 cross-account isolation is absolute
- AD-SEC-* security, identity, and tenancy

## Scope

In scope:
- Add Sobelow dependency/configuration when Phoenix project exists.
- Add CI job running `mix sobelow --config`.
- Document any accepted false positives.

Out of scope:
- Dependency audit or secret scanning.

## Expected behavior

Phoenix security findings are surfaced on PRs.

## Acceptance criteria

- [ ] Sobelow can run locally when Phoenix exists.
- [ ] CI job runs Sobelow.
- [ ] False-positive handling is documented and reviewable.

## Required tests

- [ ] `mix sobelow --config` when project exists.

## Risk class

- [x] High: tenancy/security/audit/pipeline/release/migration

## Codex instruction

Security-sensitive changes require human review.
```

## Task 15: Add CI: dependency audit

Recommended labels: `security-sensitive`

```md
## Goal

Add a CI lane for dependency vulnerability auditing.

## Architecture anchors

Relevant anchors:
- AINV-2 user owns data and keys
- AD-SEC-* security, identity, and tenancy

## Scope

In scope:
- Add dependency audit tooling appropriate for Elixir once `mix.exs` exists.
- Add CI job running `mix deps.audit` or the chosen equivalent.

Out of scope:
- Sobelow, container scans, SBOM.

## Expected behavior

Known vulnerable dependencies fail or clearly report in CI.

## Acceptance criteria

- [ ] Dependency audit command exists.
- [ ] CI job runs the audit command.
- [ ] Failure policy is documented.

## Required tests

- [ ] `mix deps.audit` or equivalent when project exists.

## Risk class

- [x] High: tenancy/security/audit/pipeline/release/migration

## Codex instruction

Do not suppress dependency findings without human approval.
```

## Task 16: Add CI: SQLite test lane

Recommended labels: `backend-parity-required`

```md
## Goal

Add a deterministic SQLite/single-node test lane.

## Architecture anchors

Relevant anchors:
- AINV-1 one codebase, two modes, identical guarantees
- AD-SEAM-2 storage/vector/lexical ports

## Scope

In scope:
- Add CI job for `CARTULARY_DATA_LAYER=sqlite`.
- Run `MIX_ENV=test CARTULARY_DATA_LAYER=sqlite mix test --only sqlite` once tests exist.
- Keep this lane separate from Postgres.

Out of scope:
- Postgres lane.
- Implementing SQLite resources beyond what current tests require.

## Expected behavior

SQLite-specific behavior is tested independently.

## Acceptance criteria

- [ ] SQLite CI job exists.
- [ ] Job sets data-layer environment explicitly.
- [ ] Job runs only SQLite-marked tests.

## Required tests

- [ ] `MIX_ENV=test CARTULARY_DATA_LAYER=sqlite mix test --only sqlite` when project exists.

## Risk class

- [x] Medium: normal source change

## Codex instruction

Do not fake backend parity; mark unavailable checks honestly until tests exist.
```

## Task 17: Add CI: Postgres test lane

Recommended labels: `backend-parity-required`

```md
## Goal

Add a deterministic Postgres/queue-mode test lane.

## Architecture anchors

Relevant anchors:
- AINV-1 one codebase, two modes, identical guarantees
- AD-SEAM-2 storage/vector/lexical ports

## Scope

In scope:
- Add CI job with Postgres service, preferably pgvector image when needed.
- Set `CARTULARY_DATA_LAYER=postgres`.
- Run `MIX_ENV=test CARTULARY_DATA_LAYER=postgres mix test --only postgres` once tests exist.

Out of scope:
- SQLite lane.
- Production database provisioning.

## Expected behavior

Postgres-specific behavior is tested independently.

## Acceptance criteria

- [ ] Postgres CI job exists.
- [ ] Job starts a Postgres service.
- [ ] Job sets data-layer environment explicitly.
- [ ] Job runs only Postgres-marked tests.

## Required tests

- [ ] `MIX_ENV=test CARTULARY_DATA_LAYER=postgres mix test --only postgres` when project exists.

## Risk class

- [x] Medium: normal source change

## Codex instruction

Do not fake backend parity; mark unavailable checks honestly until tests exist.
```

## Task 18: Add merge_group trigger

Recommended labels: `good-first-agent-task`

```md
## Goal

Ensure CI workflows include the `merge_group` trigger required for merge queue
compatibility.

## Architecture anchors

Relevant anchors:
- AD-EVAL-* deterministic PR gate

## Scope

In scope:
- Add `merge_group` to CI workflows that provide required checks.
- Document why merge queue checks must run on `merge_group`.

Out of scope:
- Enabling merge queue in GitHub settings.
- Adding new CI jobs.

## Expected behavior

Required checks can report for merge queue branches when merge queue is enabled.

## Acceptance criteria

- [ ] Required-check workflows include `merge_group`.
- [ ] Documentation notes that GitHub settings still require human setup.

## Required tests

- [ ] Workflow syntax inspection.

## Risk class

- [x] Low: docs/tests/internal cleanup

## Codex instruction

Keep this PR limited to triggers/documentation.
```

## Task 19: Enable Codex Cloud

Recommended labels: `human-only`

```md
## Goal

Enable Codex Cloud for the repository through the GitHub/OpenAI integration.

## Architecture anchors

Relevant anchors:
- AINV-1 one codebase, two modes, identical guarantees

## Scope

In scope:
- Human connects Codex Cloud to the repo with minimal required access.
- Document the configuration in `docs/roadmap/` if needed.

Out of scope:
- Repo code changes unless documenting the completed setup.
- Automatic PR reviews.
- Codex GitHub Action workflows.

## Expected behavior

A maintainer can start manual Codex tasks against the repository.

## Acceptance criteria

- [ ] Human confirms Codex Cloud can access the repo.
- [ ] Human confirms access scope is minimal.
- [ ] Any repo-visible setup notes are documented.

## Required tests

- [ ] Human verifies Codex Cloud can read the repo.

## Risk class

- [x] Human-only: architecture/licensing/security model

## Codex instruction

Codex cannot complete this without human repository/organization access.
```

## Task 20: Enable Codex PR review

Recommended labels: `human-only`

```md
## Goal

Enable manual Codex PR review for Cartulary.

## Architecture anchors

Relevant anchors:
- AD-EVAL-* deterministic PR gate and review support

## Scope

In scope:
- Human enables Codex PR review integration.
- Start with manual `@codex review`.
- Document when automatic reviews may be enabled later.

Out of scope:
- Making Codex review a required status check.
- Codex GitHub Action workflows.

## Expected behavior

A maintainer can request Codex review on a PR.

## Acceptance criteria

- [ ] Human confirms `@codex review` works on a test PR.
- [ ] Automatic reviews remain disabled or explicitly justified.
- [ ] `AGENTS.md` is used as repo guidance.

## Required tests

- [ ] Manual test PR with `@codex review`.

## Risk class

- [x] Human-only: architecture/licensing/security model

## Codex instruction

Codex cannot enable this integration without human repository/organization access.
```

## Task 21: Add `.github/codex/prompts/pr-risk-review.md`

Recommended labels: `ai-review-only`

```md
## Goal

Add the first GitHub-side Codex prompt for PR risk review.

## Architecture anchors

Relevant anchors:
- AINV-6 cross-account isolation is absolute
- AD-EVAL-* deterministic gate and advisory review separation

## Scope

In scope:
- Add `.github/codex/prompts/pr-risk-review.md`.
- Prompt should ask for risk summary, affected invariants, security/tenancy/audit
  concerns, backend parity concerns, and missing tests.
- State that the prompt is advisory unless a later task makes structured output required.

Out of scope:
- Codex GitHub Action workflow.
- Required status check.
- Automatic posting permissions.

## Expected behavior

The repo has a reviewable prompt ready for future GitHub-side Codex automation.

## Acceptance criteria

- [ ] Prompt file exists.
- [ ] Prompt focuses on serious risks and invariant violations.
- [ ] Prompt does not ask Codex to apply patches or approve merges.

## Required tests

- [ ] Documentation inspection.

## Risk class

- [x] Low: docs/tests/internal cleanup

## Codex instruction

Do not add active Codex Action workflows in this task.
```

## Task 22: Add first ADR: repo automation model

Recommended labels: `good-first-agent-task`, `ai-ready`

```md
## Goal

Add the first ADR documenting Cartulary's repository automation model.

## Architecture anchors

Relevant anchors:
- AINV-1 one codebase, two modes, identical guarantees
- AD-EVAL-* deterministic PR gate

## Scope

In scope:
- Add `docs/adr/0001-repo-automation-model.md`.
- Record the decision to use issue-scoped Codex work, deterministic CI, Codex
  review, CODEOWNER review, and human merge gates.

Out of scope:
- L3 boundary ADR.
- Changing GitHub settings.

## Expected behavior

Future contributors can understand why the repo uses a controlled automation
model instead of AI auto-merge.

## Acceptance criteria

- [ ] ADR exists with status, context, decision, consequences, and anchors.
- [ ] ADR aligns with `AGENTS.md` and `l3-automation-flow.md`.

## Required tests

- [ ] Documentation inspection.

## Risk class

- [x] Low: docs/tests/internal cleanup

## Codex instruction

Keep this ADR focused on repository automation mechanics.
```

## Task 23: Add first ADR: L3 automation boundary

Recommended labels: `good-first-agent-task`, `ai-ready`

```md
## Goal

Add an ADR documenting the boundary of L3 automation for Cartulary.

## Architecture anchors

Relevant anchors:
- AINV-1 one codebase, two modes, identical guarantees
- AINV-6 cross-account isolation is absolute
- AD-EVAL-* deterministic PR gate

## Scope

In scope:
- Add `docs/adr/0002-l3-automation-boundary.md`.
- Record that Codex may implement well-scoped issues but must not auto-merge.
- Document human-only areas: prime directive, licensing, security model,
  data/export promises, multi-tenancy architecture, breaking API behavior.

Out of scope:
- Repo automation ADR.
- GitHub settings changes.

## Expected behavior

The repo has a durable decision record defining what L3 does and does not mean.

## Acceptance criteria

- [ ] ADR exists with status, context, decision, consequences, and anchors.
- [ ] ADR explicitly rejects source-code auto-merge for now.
- [ ] ADR lists human-only decision areas.

## Required tests

- [ ] Documentation inspection.

## Risk class

- [x] Low: docs/tests/internal cleanup

## Codex instruction

Keep this ADR focused on the L3 automation boundary.
```

## Task 24: Scaffold Mix project

Recommended labels: `backend-parity-required`

```md
## Goal

Scaffold the initial Elixir Mix project shape for Cartulary.

## Architecture anchors

Relevant anchors:
- AINV-1 one codebase, two modes, identical guarantees
- AD-LANG-1 Elixir, single language for the engine
- AD-TOPO-1 Mix umbrella or single app with clear internal boundaries

## Scope

In scope:
- Create the initial Mix project structure agreed by the maintainer: umbrella or
  single app with boundary-enforced contexts.
- Add minimal test setup.
- Keep app naming consistent with Cartulary.

Out of scope:
- Phoenix endpoint.
- Ash resources.
- Runtime config validation.
- Docker.

## Expected behavior

`mix test` can run against an empty/minimal project.

## Acceptance criteria

- [ ] `mix.exs` exists.
- [ ] Basic app/test structure exists.
- [ ] `mix test` passes.
- [ ] Project shape is documented if a choice was made between umbrella and single app.

## Required tests

- [ ] `mix format --check-formatted`
- [ ] `mix compile --warnings-as-errors`
- [ ] `mix test`

## Risk class

- [x] Medium: normal source change

## Codex instruction

Ask for human confirmation if umbrella vs single app has not been decided in the
issue body.
```

## Task 25: Scaffold Phoenix endpoint

Recommended labels: `backend-parity-required`

```md
## Goal

Add the minimal Phoenix endpoint shell.

## Architecture anchors

Relevant anchors:
- AD-LANG-1 Elixir/BEAM
- AD-TOPO-2 Ash-shaped module graph and Phoenix surfaces

## Scope

In scope:
- Add Phoenix dependency/configuration appropriate for the selected Mix project.
- Add a minimal endpoint/router structure.
- Keep LiveView/governance UI out of scope.

Out of scope:
- Health endpoint implementation if reserved for Task 26.
- AshJsonApi resources.
- Authentication/tenancy.

## Expected behavior

Phoenix application structure exists and compiles.

## Acceptance criteria

- [ ] Phoenix endpoint module exists.
- [ ] Router module exists.
- [ ] App compiles with warnings as errors.
- [ ] No business routes are added yet.

## Required tests

- [ ] `mix format --check-formatted`
- [ ] `mix compile --warnings-as-errors`
- [ ] `mix test`

## Risk class

- [x] Medium: normal source change

## Codex instruction

Keep this to the Phoenix shell only.
```

## Task 26: Add health endpoint

Recommended labels: `good-first-agent-task`

```md
## Goal

Add a minimal HTTP health endpoint.

## Architecture anchors

Relevant anchors:
- AD-DEPLOY-1 one image, one program, scaled by node count
- NFR-* availability and operations targets

## Scope

In scope:
- Add a lightweight route such as `GET /health`.
- Return a simple success response without leaking secrets or environment details.
- Add tests for the endpoint.

Out of scope:
- Deep database health checks.
- Authenticated readiness/liveness split unless specified.

## Expected behavior

A caller can verify the Phoenix app is alive.

## Acceptance criteria

- [ ] `GET /health` returns 200.
- [ ] Response does not expose secrets or sensitive config.
- [ ] Test covers the endpoint.

## Required tests

- [ ] `mix format --check-formatted`
- [ ] `mix compile --warnings-as-errors`
- [ ] `mix test`

## Risk class

- [x] Low: docs/tests/internal cleanup

## Codex instruction

Do not add broader observability or readiness behavior unless specified.
```

## Task 27: Add runtime config validation

Recommended labels: `security-sensitive`, `backend-parity-required`

```md
## Goal

Add initial runtime configuration validation.

## Architecture anchors

Relevant anchors:
- AINV-1 one codebase, two modes, identical guarantees
- AINV-2 user owns data and keys
- AD-CONFIG-* configuration, packaging, distribution

## Scope

In scope:
- Validate required runtime mode/data-layer settings.
- Fail fast on invalid deployment mode or data-layer configuration.
- Avoid logging secrets.

Out of scope:
- Full production secrets backend.
- Deployment manifests.

## Expected behavior

Invalid runtime configuration fails clearly and safely at boot/config validation
time.

## Acceptance criteria

- [ ] Runtime config validation exists.
- [ ] Invalid data-layer/mode values fail clearly.
- [ ] Secret values are not logged.
- [ ] Tests cover valid and invalid configuration paths where feasible.

## Required tests

- [ ] `mix format --check-formatted`
- [ ] `mix compile --warnings-as-errors`
- [ ] `mix test`

## Risk class

- [x] High: tenancy/security/audit/pipeline/release/migration

## Codex instruction

Treat config as security-sensitive. Do not introduce secret logging.
```

## Task 28: Add Dockerfile

Recommended labels: `pipeline-sensitive`

```md
## Goal

Add an initial Dockerfile for the Cartulary application.

## Architecture anchors

Relevant anchors:
- AD-DEPLOY-1 one image, one program, scaled by node count
- AD-CONFIG-* packaging and distribution

## Scope

In scope:
- Add Dockerfile appropriate for the Mix release/project shape.
- Prefer reproducible, minimal runtime image practices.
- Do not bake secrets into the image.

Out of scope:
- GHCR publish workflow.
- SBOM and image scanning.
- Compose file if reserved for Task 29.

## Expected behavior

A container image can be built locally once the Mix project is scaffolded.

## Acceptance criteria

- [ ] Dockerfile exists.
- [ ] Build does not require secrets.
- [ ] Runtime config remains environment-driven.
- [ ] Local build instructions are documented.

## Required tests

- [ ] `docker build .` or documented equivalent when project exists.
- [ ] `mix test` before image build if project exists.

## Risk class

- [x] Medium: normal source change

## Codex instruction

Do not add publishing credentials or release automation in this task.
```

## Task 29: Add single-node compose

Recommended labels: `pipeline-sensitive`, `backend-parity-required`

```md
## Goal

Add a local single-node Docker Compose file.

## Architecture anchors

Relevant anchors:
- AINV-1 one codebase, two modes, identical guarantees
- AD-DEPLOY-1 one image, one program
- AD-SEAM-2 SQLite single-node storage and Oban Lite

## Scope

In scope:
- Add compose file for local single-node mode.
- Use SQLite/single-node defaults.
- Keep Redis out of the stack.
- Document how to start and stop it.

Out of scope:
- Queue-mode Postgres compose.
- Production deployment manifests.

## Expected behavior

A developer can run the single-node app locally with compose once the app image
exists.

## Acceptance criteria

- [ ] Compose file exists.
- [ ] It does not include Redis.
- [ ] It uses single-node/SQLite-oriented configuration.
- [ ] Startup instructions are documented.

## Required tests

- [ ] `docker compose config`
- [ ] `docker compose up` when the app can run.

## Risk class

- [x] Medium: normal source change

## Codex instruction

Do not add queue-mode compose unless separately scoped.
```

## Task 30: Create Milestone M1: single-node runnable skeleton

Recommended labels: `human-only`

```md
## Goal

Create the GitHub milestone for M1: single-node runnable skeleton.

## Architecture anchors

Relevant anchors:
- AINV-1 one codebase, two modes, identical guarantees
- AD-DEPLOY-1 one image, one program

## Scope

In scope:
- Human creates a GitHub milestone named `M1: single-node runnable skeleton`.
- Add description and exit criteria.
- Attach relevant tasks/issues after they exist.

Out of scope:
- Implementing Mix/Phoenix/Docker changes.
- Creating later milestones unless separately requested.

## Expected behavior

The repository has a milestone tracking completion of the single-node runnable
skeleton.

## Acceptance criteria

- [ ] Milestone exists in GitHub.
- [ ] Milestone description includes exit criteria: `docker compose up` works,
  `mix test` works, Phoenix health endpoint works, repo boundaries are visible,
  and Codex can add a small Ash resource without inventing structure.
- [ ] Related issues are assigned to the milestone.

## Required tests

- [ ] Human verifies milestone in GitHub.

## Risk class

- [x] Human-only: architecture/licensing/security model

## Codex instruction

Codex cannot create this milestone without GitHub access. If GitHub access is not
available, provide exact UI/CLI instructions for the human maintainer.
```
