# Architecture notes

This directory is for implementation-facing architecture notes derived from the
blueprint specs.

Authoritative inputs remain:

- `specs/memory-system-functional-requirements.md` for product behavior and
  stable `FR-*` anchors.
- `specs/memory-system-architecture-and-nfr.md` for architecture decisions,
  non-functional targets, and `AD-*` / `AINV-*` / `NFR-*` anchors.
- `specs/memory-system-product-blueprint.md` for product positioning,
  sequencing, and go-to-market context.

Keep notes here short, traceable to blueprint anchors, and subordinate to the
spec documents until a later task promotes them into formal implementation
specifications.

The current implementation log is `docs/implementation-status.md`. Treat it as
evidence of what runs today and as a debt list, not as a replacement for the
architecture specs or ADRs.

The architecture-first description of the complete free self-host core is
`docs/architecture/free-core-architecture.md`. It records the target
abstraction layers, module decomposition, and durable-versus-derived rules
while remaining subordinate to the blueprint anchors above. Outstanding
delivery work lives in `docs/roadmap/beta-roadmap.md`.

The current development observability runbook is
`docs/observability/README.md`. Use it for local OpenTelemetry collection,
Langfuse forwarding, trace/log safety defaults, and experiment measurement
discipline.

The implemented Ash domain backbone resource/action/policy boundary and its
remaining transition tickets are recorded in
`docs/architecture/ash-domain-backbone.md`.

The implemented Gate A/B governance matrix, validation/consent lifecycle, human
and MCP adapters, erasure semantics, and `f4-1` contract transition are
recorded in `docs/architecture/gate-a-b-governance.md`.

The implemented model-layer provider roles, structured validation/repair, local
Ortex/ONNX embedder, model provenance, exact usage ledger, and `f5-1`
extraction transition are recorded in
`docs/architecture/model-layer-structured-extraction.md`.

The implemented document/blob boundary, native extraction, RAG chunking,
dual-ingest pipeline, incremental connector sync, immutable supersession,
tombstones, erasure, and document portability seam are recorded in
`docs/architecture/documents-connectors-sync.md`.

The implemented retrieval strategies, entity resolution privacy, projections,
and reasoning-free context boundary are recorded in
`docs/architecture/retrieval-entity-context.md`.

The implemented procedural-memory and skill-readiness boundary is recorded
in `docs/architecture/skill-readiness-procedural-memory.md`.

The implemented packaging, portability, runtime validation, readiness,
metering, and operations boundary is recorded in
`docs/architecture/portability-packaging-operations.md`.

The implemented deterministic evaluation gates, evaluation provenance,
database-mode CI parity, semantic versioning, changelog, and release controls
are recorded in `docs/architecture/evaluation-ci-release-readiness.md`.
