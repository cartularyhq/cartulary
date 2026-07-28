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

The current local POC implementation log is `docs/poc-local-proof.md`. Treat it
as evidence of what runs today and as a debt list, not as a replacement for the
architecture specs or ADRs.

The architecture-first execution plan for completing the free self-host core is
`docs/roadmap/free-core-roadmap.md`. It records the target abstraction layers,
module decomposition, POC migration posture, and implementation phases while
remaining subordinate to the blueprint anchors above.

The current development observability runbook is
`docs/observability/README.md`. Use it for local OpenTelemetry collection,
Langfuse forwarding, trace/log safety defaults, and experiment measurement
discipline.

The implemented F1 resource/action/policy boundary and its remaining transition
tickets are recorded in `docs/architecture/f1-ash-domain-backbone.md`.

The implemented F4 Gate A/B matrix, validation/consent lifecycle, human and MCP
adapters, erasure semantics, and `f4-1` contract transition are recorded in
`docs/architecture/f4-real-gate-a-b-governance.md`.

The implemented F5 provider roles, structured validation/repair, local
Ortex/ONNX embedder, model provenance, exact usage ledger, and `f5-1`
extraction transition are recorded in
`docs/architecture/f5-model-layer-structured-extraction.md`.
