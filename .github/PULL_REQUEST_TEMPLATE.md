## Summary

- What changed?
- Why is this the smallest useful change for the linked issue?

## Linked issue

<!-- Required: always mention the issue this PR implements. Use a closing keyword when appropriate, for example: `Closes #9` or `Closes https://github.com/cartularyhq/cartulary/issues/9`. -->

Closes #

## Reference docs

<!-- List the internal docs actually used to scope, implement, and review this PR. Include the closest specific document(s), not every possible doc. Use `N/A` only when a category truly does not apply. -->

- Blueprint requirements: `specs/memory-system-functional-requirements.md` (`FR-*` anchors):
- Blueprint architecture/NFRs: `specs/memory-system-architecture-and-nfr.md` (`AD-*`, `AINV-*`, `NFR-*` anchors):
- Product context: `specs/memory-system-product-blueprint.md`:
- ADRs: `docs/adr/README.md` or `docs/adr/<adr-file>.md`:
- Architecture notes: `docs/architecture/README.md` or `docs/architecture/<note>.md`:
- Roadmap/process docs: `docs/roadmap/beta-roadmap.md`:
- Security/eval docs: `docs/security/README.md`, `docs/eval/README.md`, or a specific note:
- Other internal docs:

## Architecture anchors

List the blueprint anchors this PR depends on or preserves. Use `N/A` only for truly mechanical changes.

- `AINV-1` — one codebase, two deployment modes, identical guarantees:
- `AINV-6` — account isolation; account derived from identity, never request parameters:
- `AD-EVAL-*` — deterministic PR gate and eval separation:
- Other `FR-*`, `AD-*`, `AINV-*`, or `NFR-*` anchors:

## Self-explanatory code

Every touched file must be readable on its own, without opening `specs/` or
`docs/`. See the "Coding conventions" section of `AGENTS.md`.

- [ ] Every module touched has a real `@moduledoc`; no `@moduledoc false` added
- [ ] New or changed public functions have a `@doc` covering return shape and failure modes
- [ ] No comment or docstring points at a spec, ADR, roadmap item, or blueprint anchor
- [ ] Comments explain why, not what, and no comment contradicts the code it sits next to

## Risk class

Select one and explain the reviewer attention needed.

- [ ] Low — docs, tests, or internal cleanup only
- [ ] Medium — behavior, schema, dependency, or operational change
- [ ] High — security, tenancy, audit, data-loss, migration, release, or production-risk change

Risk rationale:

## AI usage accountability

- [ ] No AI used
- [ ] AI-assisted implementation
- [ ] AI-assisted review
- [ ] AI-assisted test generation
- [ ] AI-assisted documentation

If AI was used, name the tool/model and summarize human verification performed:

## Test evidence

List every check actually run. Include command, result, and any relevant output or artifact link.

```bash
# command
# result/output summary
```

If a standard check was not run, explain why:

## Backend parity

Does this PR affect pg0 single-node mode, external-Postgres queue-mode, queues, storage, retrieval, or derived caches?

- [ ] No backend-parity impact
- [ ] Parity evidence provided for packaged pg0/single-node
- [ ] Parity evidence provided for external Postgres/queue-mode
- [ ] Parity lane not yet available; limitation explained below

Parity notes:

## Security, tenancy, and audit impact

- [ ] No security, tenancy, or audit impact
- [ ] Security impact reviewed
- [ ] Tenancy/account-isolation impact reviewed
- [ ] Audit/ledger/history impact reviewed

Notes, including how `AINV-6` is preserved when relevant:

## Migration impact

- [ ] No migrations or data backfills
- [ ] Reversible migration included
- [ ] Irreversible migration or backfill; rollback/restore plan documented

Migration notes:

## Release-note impact

- [ ] No release note needed
- [ ] User-facing change; release note drafted
- [ ] Operator-facing change; release note drafted
- [ ] Breaking change; migration/upgrade note drafted

Release note draft or rationale:
