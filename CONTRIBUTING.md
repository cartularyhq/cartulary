# Contributing to Cartulary

Thank you for helping build Cartulary. This repository runs a deliberately
cautious flow: one scoped task, one issue, one branch, one pull request. Humans
remain the merge gate, and the `core` team owns every repository area for
review and stewardship.

## Operating contract

Before contributing, read `AGENTS.md`. It is the operating contract for human
contributors and coding agents alike. It defines the product and architecture
invariants, the coding conventions, the required local checks, and the review
posture.

`README.md` is the fastest orientation: core concepts, how a request flows
through the system, the repository layout, and where to start reading.

For a change that alters product behaviour, also read the smallest relevant set
of blueprint anchors in:

- `specs/memory-system-functional-requirements.md`
- `specs/memory-system-architecture-and-nfr.md`
- `specs/memory-system-product-blueprint.md`
- `specs/memory-system-evaluation-framework.md`

Preserve the meaning of existing `FR-*`, `AD-*`, `AINV-*`, `NFR-*`, and `EV-*`
anchors unless an issue explicitly asks for a blueprint change. Three that
constrain almost everything:

- one codebase, two deployment modes, identical guarantees;
- Account is derived from the authenticated identity, never from a request
  parameter;
- the pipeline is the only writer of knowledge.

## Code must stand on its own

Cartulary treats source files as the primary documentation. A developer who has
never opened `specs/` or `docs/` must be able to read any file and understand
what it does, why it exists, and which rules it enforces.

The full rules are the "Coding conventions" section of `AGENTS.md`. The parts
contributors get wrong most often:

- **Do not cite design documents from code.** No `see docs/architecture/...`,
  no `per FR-KN-3` in a comment or docstring. Write the rule itself, in plain
  language, at the place that enforces it. Anchors and issue links belong in
  the commit message, the PR description, and the documents under `docs/`.
- **Every module gets a real `@moduledoc`,** and every public function a
  `@doc`. `@moduledoc false` is not acceptable in first-party code.
- **Comment the why.** Ordering constraints, transaction boundaries, tenancy
  filters, idempotency, content-safety redaction, and deliberate oddities.
  Delete comments that restate the code.
- **`F0`–`F11` are retired.** They no longer name anything and must not appear
  in prose. Contract identity strings such as `f7-1` or `cartulary-account-1`
  are data: keep the value, explain what it versions.
- **A stale comment is a defect.** Behaviour edits update the surrounding
  comment in the same patch.

## One issue, one branch, one PR

1. A human creates or approves exactly one implementation issue.
2. A human applies `ai-ready` only when an agent may implement it.
3. The contributor creates one branch for that issue.
4. The contributor implements only that issue's scope and acceptance criteria.
5. The contributor opens one focused PR that links the issue.
6. The `core` team reviews and remains the merge gate.
7. The next task starts only after the current PR is merged or closed, from the
   updated `main`.

Do not batch unrelated roadmap tasks, opportunistic cleanup, new automation,
CI, CODEOWNERS, security disclosure policy, governance changes, or licence
changes unless the current issue explicitly asks for them.

## Expectations for humans and agents

- Inspect the worktree before editing and avoid overwriting concurrent changes.
- Keep the patch small enough to review against the acceptance criteria.
- Keep code comments, docs, tests, eval fixtures, and ADRs aligned with any
  behaviour change.
- Do not introduce new deployment modes, a second runtime, or shortcuts that
  bypass the Ash/Phoenix/Oban structure described in `AGENTS.md`.
- Never remove or obscure copyright, licence, or SPDX notices, and never move a
  feature across the free-core/enterprise boundary without an explicit human
  licensing decision.

Coding agents must additionally respect the issue label rules: implement only
issues labelled `ai-ready`, and stop at the defined acceptance criteria.

## Commit and pull request expectations

A good PR includes:

- a concise title naming the issue or task;
- what changed and why;
- a link to the issue, such as `Closes #6`;
- the blueprint anchors and repository instructions the implementation relied
  on — in the PR text, not in code comments;
- real check evidence: commands that passed, failed, or were unavailable;
- any known limitation or follow-up deliberately left out of scope.

Commit messages stay short, descriptive, and scoped to the issue. Do not
rewrite or revert another contributor's work unless the issue or a reviewer
explicitly instructs you to.

## Local checks and honest evidence

Always run the checks that exist for the state you changed. At a minimum:

```bash
git status --short
```

The standard Elixir gate:

```bash
mix deps.get
mix ash.codegen --check
mix format --check-formatted
mix compile --warnings-as-errors
mix test
```

When the change touches the relevant area, also run:

```bash
mix credo --strict
mix dialyzer
mix sobelow --config
```

For evaluation, CI, versioning, or release-readiness changes:

```bash
mix cartulary.eval.release \
  --no-model \
  --assert-thresholds \
  --output /private/tmp/cartulary-release-eval.json
mix cartulary.release.check \
  --eval-report /private/tmp/cartulary-release-eval.json
```

If a command is unavailable — no network for the pg0 lane, no local Postgres,
no repository Markdown checker — say so explicitly in the PR. Never imply that
an unavailable check passed. For documentation-only changes, inspect the
changed Markdown directly and state the inspection scope.

## Review expectations

Before requesting review, confirm the PR:

- preserves one codebase, two deployment modes, identical guarantees;
- maintains Account isolation, downward scope inheritance, governed upward
  promotion, and pipeline-only knowledge writes;
- separates durable records from rebuildable caches wherever persistence is
  touched;
- keeps Oban jobs, audit writes, lifecycle transitions, and derived-index
  updates transactionally safe;
- provides parity evidence for the supervised-pg0 and operator-run Postgres
  lanes when the change affects both, and clearly marks any lane that could not
  be run;
- leaves every touched file readable on its own, with no new pointers from code
  into `specs/` or `docs/`;
- includes real, current check evidence.

The `core` team decides whether the PR is ready to merge.
