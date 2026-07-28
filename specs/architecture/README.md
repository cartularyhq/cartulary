# Architecture notes

Implementation-facing notes about how Cartulary is built and why.

**These notes are not required reading for understanding the code.** Every
source file in this repository is written to stand on its own: modules document
what they own and what they guarantee, and comments state rules in place rather
than pointing here. What these notes add is the *reasoning* — the alternatives
considered, the trade-offs taken, the evidence behind a decision, and the
transition history of a contract identity. Read the code to learn what the
system does; read these notes to learn why it does it that way.

## Where authority lives

The blueprint specs remain authoritative for product behaviour and stable
anchors. These notes are subordinate to them.

| Source | Authoritative for |
| --- | --- |
| `specs/memory-system-functional-requirements.md` | Product behaviour, `FR-*` anchors. |
| `specs/memory-system-architecture-and-nfr.md` | Architecture decisions, non-functional targets, `AD-*` / `AINV-*` / `NFR-*` anchors. |
| `specs/memory-system-product-blueprint.md` | Product positioning, sequencing, go-to-market context. |
| `specs/memory-system-evaluation-framework.md` | Evaluation methodology and `EV-*` anchors. |
| `specs/adr/` | Decisions with alternatives weighed and a chosen outcome. |

Keep notes here short and traceable to anchors. Anchors belong in these
documents and in pull request descriptions — never in source comments.

## The notes

| Note | Covers |
| --- | --- |
| `free-core-architecture.md` | Target abstraction layers, module decomposition, durable-versus-derived rules, the public operation set, and the contract version identities. |
| `ash-domain-backbone.md` | The Ash resource, action, and policy boundary, and its remaining transition tickets. |
| `transactional-writes-audit-jobs.md` | One-transaction ingest, the hash-chain audit log, idempotency, and the Oban job lanes. |
| `identity-tenancy-rbac.md` | Password and API-key identities, identity-derived Account selection, and deny-wins role inheritance. |
| `gate-a-b-governance.md` | The gate matrix, validation and consent lifecycle, human and MCP adapters, erasure semantics, and the `f4-1` contract transition. |
| `model-layer-structured-extraction.md` | Provider roles, structured validate-and-repair, the local Ortex/ONNX embedder, model provenance, the usage ledger, and the `f5-1` extraction transition. |
| `documents-connectors-sync.md` | The document and blob boundary, native extraction, chunking, dual ingest, incremental connector sync, immutable supersession, tombstones, erasure, and the portability seam. |
| `retrieval-entity-context.md` | Seed strategies, fusion, profiles, entity-resolution privacy, projections, and the reasoning-free context boundary. |
| `skill-readiness-procedural-memory.md` | Skill requirement cards, the selector language, and the gap report. |
| `portability-packaging-operations.md` | Packaging, logical Account archives, runtime validation, readiness, metering, and operations. |
| `evaluation-ci-release-readiness.md` | Deterministic evaluation gates, report provenance, database-mode CI parity, semantic versioning, changelog, and release controls. |

## Related

- `specs/implementation-status.md` — what actually runs today, with verification
  evidence and real limitations. Treat it as evidence and a debt list, not as a
  substitute for a spec or an ADR.
- `specs/roadmap/beta-roadmap.md` — the only roadmap: outstanding work with
  acceptance criteria.
- `specs/observability/README.md` — local OpenTelemetry collection, Langfuse
  forwarding, trace and log safety defaults, and measurement discipline.
- `docs/concepts/` — the same systems described for users rather than
  implementers, published on the documentation site. When a note here changes
  behaviour a user can observe, update the matching page there in the same
  patch.
