# Contributing to Cartulary

Thank you for helping build Cartulary. This repository currently uses a cautious
L3 automation flow: one scoped task, one issue, one branch, and one pull request.
Humans remain the merge gate, and the `core` team owns all repository areas for
review and stewardship purposes.

## Operating contract

Before contributing, read `AGENTS.md`. It is the repository operating contract
for both human contributors and Codex agents. It defines the current product and
architecture invariants, the required local checks, and the review posture for
Cartulary.

For any change, also read the smallest relevant set of blueprint anchors in:

- `blueprint/memory-system-functional-requirements.md`
- `blueprint/memory-system-architecture-and-nfr.md`
- `blueprint/memory-system-product-blueprint.md`

Preserve the meaning of existing `FR-*`, `AD-*`, `AINV-*`, and `NFR-*` anchors
unless an issue explicitly asks for a blueprint change. For example, changes that
touch application structure or contribution guidance should remain consistent
with:

- `AINV-1`: one codebase, two deployment modes, identical guarantees.
- `AINV-6`: account is derived from identity, never request parameters.
- `AD-TOPO-1`: one Mix umbrella or single app with clear internal boundaries.

## One issue, one branch, one PR

Cartulary contributions should be focused and traceable:

1. A human creates or approves exactly one implementation issue.
2. A human applies `ai-ready` only when Codex may implement the issue.
3. The contributor creates one branch for that issue.
4. The contributor implements only the issue scope and acceptance criteria.
5. The contributor opens one focused PR that links the issue.
6. The `core` team reviews the PR and remains the merge gate.
7. The next task starts only after the current PR is merged or closed.

Do not batch unrelated roadmap tasks, opportunistic cleanup, new automation, CI,
CODEOWNERS, security disclosure policy, governance changes, or license changes
unless the current issue explicitly asks for them.

## Expectations for humans and Codex

All contributors should:

- Inspect the worktree before editing and avoid overwriting concurrent changes.
- Keep the patch small enough to review against the issue acceptance criteria.
- Cite the relevant blueprint anchors in design notes, code comments, docs, or PR
  text when the change depends on those anchors.
- Keep docs, tests, and architecture notes aligned with behavior changes.
- Avoid introducing new deployment modes, second runtimes, or shortcuts that
  bypass the Ash/Phoenix/Oban architecture described in `AGENTS.md`.

Codex agents must additionally follow the label and scope rules in the issue:
only implement issues labeled `ai-ready`, and stop at the defined acceptance
criteria.

## Commit and pull request expectations

A good PR should include:

- A concise title that names the issue or task.
- A description of what changed and why.
- A link to the issue, such as `Closes #6`.
- The blueprint anchors or repo instructions considered during implementation.
- Real test or inspection evidence, including commands that passed, failed, or
  were unavailable.
- Any known limitations or follow-up work that is intentionally left out of
  scope.

Commit messages should be short, descriptive, and scoped to the issue. Do not
rewrite or revert another contributor's work unless the issue or reviewer
explicitly instructs you to do so.

## Local checks and honest evidence

Always run the checks that exist for the repository state you changed. At a
minimum, run:

```bash
git status --short
```

When `mix.exs` exists, run the standard Elixir gate:

```bash
mix deps.get
mix format --check-formatted
mix compile --warnings-as-errors
mix test
```

When the relevant tools and configuration exist, also run applicable checks such
as:

```bash
mix credo --strict
mix dialyzer
mix sobelow --config
```

If a command is not available because the Mix/Phoenix project, dependencies, CI,
or a repository-local Markdown/link checker does not exist yet, report that
honestly in the PR. Do not imply that unavailable checks passed. For
documentation-only changes before the project exists, inspect the changed
Markdown directly and state the inspection scope.

## Review expectations

Before requesting review, confirm that the PR:

- Preserves the prime directive: one codebase, two deployment modes, identical
  guarantees.
- Maintains the account isolation and scope inheritance posture described by the
  blueprint.
- Separates durable records from rebuildable caches when persistence is touched.
- Provides parity evidence for SQLite/single-node and Postgres/queue-mode lanes
  when those lanes exist and the change affects both modes.
- Avoids active automation or tooling unless the issue explicitly asks for it.
- Includes real, current check evidence.

The `core` team decides whether the PR is ready to merge.
