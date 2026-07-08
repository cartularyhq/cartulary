# Cartulary agent operating contract

This file is the top-level operating contract for agents and human contributors
working in this repository. It applies to the entire repository tree unless a
more deeply nested `AGENTS.md` overrides it for a subdirectory.

## Read first

Before editing, read the smallest authoritative set needed for the task:

1. This `AGENTS.md`.
2. The relevant blueprint anchors in:
   - `blueprint/memory-system-functional-requirements.md`
   - `blueprint/memory-system-architecture-and-nfr.md`
   - `blueprint/memory-system-product-blueprint.md`
3. For automation/process work, also read:
   - `docs/roadmap/l3-automation-flow.md`
   - `docs/roadmap/manual-automation-setup.md`
4. Any ADRs, architecture notes, eval notes, security notes, or nested
   instructions that govern the files you will touch.

Blueprint anchors are stable review handles. Preserve existing `FR-*`, `AD-*`,
`AINV-*`, and `NFR-*` meanings unless the task explicitly asks for a blueprint
change.

## Prime directive

Cartulary follows the ARCH prime directive:

> One codebase, two deployment modes, identical guarantees.

Single-node and queue-mode are the same Mix release with different adapters and
runtime configuration, never forks or simplified reimplementations. Free/core
and enterprise code may be licence-gated, but the community build must remain
coherent and buildable in isolation.

## Architecture posture

Cartulary is an Elixir/Ash/Phoenix/Oban system:

- **Runtime:** Elixir on the BEAM; one Mix release, no second engine runtime.
- **Domain model:** Ash Domains, Resources, Actions, policies, and data layers
  carry the ports-and-adapters structure.
- **Surfaces:** Phoenix HTTP, LiveView, Channels/PubSub, AshJsonApi, gateway
  proxy, and the `ash_ai` MCP server where appropriate.
- **Jobs:** Oban through AshOban. Use `Oban.Engines.Lite` for SQLite
  single-node mode and the Postgres engine for queue-mode. Do not introduce
  Redis/BullMQ or a separate worker fleet.
- **Storage:** AshSqlite + SQLite FTS5 + in-memory HNSW cache in single-node;
  AshPostgres + pgvector + Postgres FTS in queue-mode. Keep vector/lexical
  indices and projections as rebuildable derived caches.
- **Models:** provider-neutral model roles over ReqLLM; self-hosted and
  OpenAI-compatible endpoints must remain possible. Default embedding strategy
  should remain compatible with local/offline Ortex/ONNX.
- **Extraction/retrieval:** prefer native Elixir/Rust/C-NIF integrations already
  named by the blueprint (Extractous/MDEx, `bitcrowd/rag`, hnswlib) before
  bespoke infrastructure.

## Non-negotiable product and architecture invariants

Treat these as hard constraints during design, implementation, review, and
refactoring:

1. **Context flows down freely; knowledge flows up only through Gate B.**
2. **Agents submit raw observations only; the pipeline is the sole writer of
   knowledge.**
3. **Blast radius scales the bar:** wider exposure requires stronger confidence,
   sensitivity handling, and consent.
4. **Knowledge is the only atom; profiles, scope cards, and session summaries
   are projections.**
5. **Reasoned artifacts pass validation gates; authored artifacts use plain
   versioning.**
6. **Belief-time, valid-time, and salience are independent; confidence and
   sensitivity are independent; subject and source are independent.**
7. **Everything scoped inherits down the containment tree, nearest-wins.**
8. **Cross-account isolation is absolute. Account is derived from identity, not
   from request parameters.**
9. **The user owns the data and keys.** Core paths must not require a proprietary
   managed service.
10. **System of record and derived caches are distinct.** Raw messages,
    validated knowledge, and audit logs are durable; queues, projections,
    lexical/vector indices, HNSW, ETS, and `persistent_term` caches are
    rebuildable.
11. **Transactional integrity is mandatory.** State changes, audit entries, and
    Oban enqueue/outbox effects that belong to one operation commit together.
12. **Infrastructure ports and domain strategies are different seams.** Swapping
    AshSqlite for AshPostgres changes where data lives, not product behavior;
    swapping a retrieval or gate strategy changes behavior and needs explicit
    review.

## Development discipline

- Keep each change traceable to the task, issue, and blueprint anchors it
  implements.
- Implement only the requested scope. Do not opportunistically add later-roadmap
  artifacts such as `CONTRIBUTING.md`, `SECURITY.md`, PR templates,
  CODEOWNERS, CI workflows, prompt wiring, or automation unless the current task
  explicitly asks for them.
- You are not alone in this codebase. Inspect the worktree before editing, avoid
  overwriting concurrent changes, and never revert or rewrite another person's
  edits unless the task explicitly authorizes it.
- Prefer small, reviewable patches. One behavior change should have one obvious
  home and one obvious set of tests.
- Keep docs, code, tests, eval fixtures, and ADRs aligned. If behavior changes,
  update the closest durable documentation or explain why no doc update is
  needed.
- Do not invent architecture that bypasses Ash, Phoenix, Oban, or the blueprint
  seams. If a new seam is unavoidable, document the reason and cite anchors.
- Do not put `try`/`catch` or equivalent defensive wrappers around imports or
  aliases. Fix dependency/configuration problems directly.

## Required local checks before opening a PR

Run the checks that exist for the repository state you are editing and report
all results in the PR and final response. Some commands below will not be
runnable until the Mix/Phoenix project exists; when a command is unavailable,
state that explicitly rather than fabricating evidence.

Minimum checks for every task:

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

When the relevant tools/configuration exist, also run the applicable checks:

```bash
mix credo --strict
mix dialyzer
mix sobelow --config
```

For documentation-only changes before the project exists, inspect the changed
Markdown directly and run any available repo-local Markdown or link check. If no
such tool exists, say so and include the manual inspection scope.

For changes touching both SQLite/single-node and Postgres/queue-mode behavior,
provide parity evidence for both backends once those test lanes exist. Until
then, clearly mark the missing lane as not yet available.

## Review guidance

Reviewers and agents should ask:

- Does the change preserve the prime directive: one codebase, two modes,
  identical guarantees?
- Does it maintain Account isolation, downward inheritance, governed upward
  promotion, and pipeline-only knowledge writes?
- Does it distinguish durable stores from rebuildable caches?
- Are Oban jobs, audit writes, lifecycle transitions, and derived-index updates
  transactionally safe?
- Does it avoid provider, database, deployment-mode, or cloud lock-in?
- Are Free/Core and Enterprise boundaries explicit and non-forking?
- Are blueprint anchors cited where the design depends on them?
- Are test results real, current, and scoped to the change?
- Is the PR focused on one task, with no unrelated cleanup or roadmap creep?

Security-, tenancy-, audit-, pipeline-, backend-parity-, or eval-sensitive work
needs explicit reviewer attention and evidence matching that risk class.

## L3 automation discipline

Cartulary's L3 automation flow is one task, one issue, one branch, one PR:

1. A human scopes and labels exactly one implementation issue as `ai-ready`.
2. The agent reads the blueprint docs and applicable repo instructions before
   editing.
3. The agent implements only that issue's acceptance criteria.
4. The agent opens one focused PR with real check evidence and links the issue.
5. A human reviews and remains the merge gate.
6. The next task starts only after merge from the updated main branch.

Do not batch unrelated practical tasks. Prefer inert, reviewable documentation
until repository settings, labels, CI, branch protection, Codex integration,
secrets, and external automation have been configured by a human maintainer.
