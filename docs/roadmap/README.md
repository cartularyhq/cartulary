<!-- SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0 -->

# Roadmap documentation

`beta-roadmap.md` is the only roadmap. It lists the work that is still
outstanding for the community beta and the definition of done for 1.0, and it
carries the delivery workflow and the maintainer-owned GitHub setup that used
to live in separate documents.

It replaces and merges:

- `l3-automation-flow.md` — the one-task, one-issue, one-branch, one-PR flow,
  now the "Delivery workflow" section;
- `main-branch-ruleset.md` — branch protection, now folded into
  "Repository automation and merge protection" with the already-configured
  rules removed;
- `manual-automation-setup.md` — the maintainer runbook, now reduced to the
  settings that are still missing;
- `free-core-roadmap.md` — its completed phases are gone and its durable
  architecture content moved to `docs/architecture/free-core-architecture.md`.

Related reading:

- `docs/implementation-status.md` — what actually runs today, with its
  verification evidence and known limitations.
- `docs/architecture/free-core-architecture.md` — the target decomposition,
  abstraction layers, durable-versus-derived rules, and public operation set.
- `docs/architecture/` — one note per implemented capability.
