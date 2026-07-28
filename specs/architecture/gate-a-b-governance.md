<!-- SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0 -->

# Gate A/B Governance

Gate A/B governance replaces the 0.1.0 baseline auto-activation shortcut with a
durable governance operation layer. It implements `FR-GOV-1` through
`FR-GOV-22`, including the ADR-0005 peer-inline path, while preserving
`AD-GOV-1` through `AD-GOV-5`, `AD-PIPE-2`, `AD-PIPE-8`, `AINV-1`, `AINV-2`,
and `AINV-5`.

## Boundary

`Cartulary.Governance.Engine` is the only operation layer for Gate A/B
evaluation and human decisions. `Cartulary.Governance.PeerQueue` is the
peer-delivery adapter, `Cartulary.Governance.Sweeper` owns dream-time aging,
and `Cartulary.Governance.Erasure` owns subject erasure. All durable mutations
go through Ash actions under the authenticated Account tenant and PostgreSQL
RLS.

Gate A/B governance adds eight persisted Ash resources, taking the durable
resource count from 28 to 36:

| Resource | Purpose |
| --- | --- |
| `GateRule` | Versioned confidence × target × sensitivity matrix cell |
| `ValidationItem` | Common curator/peer queue and conflict bundle |
| `GateDecision` | Immutable automatic and human gate history |
| `Consent` | Subject-owned, target-specific upward personal consent |
| `PeerQuery` | Frozen peer question over a validation item |
| `PeerQueryDelivery` | Session delivery and transcript-assurance evidence |
| `PeerAskPreference` | Peer-lowerable interruption limits |
| `ErasureRequest` | Durable proportionate/strict erasure result |

`KnowledgeItem` gains target level, verification state, held target, source
corroboration, supersession, revalidation, and deletion metadata. Knowledge
remains the only atom; queue, consent, history, and self-view records refer to
it rather than becoming a second knowledge store.

## Gate flow

Every newly extracted item starts as `proposed`. The matrix lookup uses the
nearest exact scope row, then the Account default row, then the conservative
built-in human rule.

Gate A produces one of:

- `active` for a matrix-backed automatic keep;
- `provisional` for peer-only visibility while human validation is pending;
- `rejected` for an explicit automatic or human rejection; or
- a deferred validation item for curator/peer review.

Gate B evaluates the target level, sensitivity, corroboration, and consent.
Scope/account proposals remain `held` at their source scope and are excluded
from retrieval. Personal knowledge cannot move upward until the subject grants
target-specific consent through a verified human or transcript-backed channel.
A curator approval before consent changes the validation state to
`awaiting_consent`; it does not activate or relocate the knowledge.

All human actions—approve, edit-as-replacement, reject, merge, defer, and
bulk decisions—enter through `Engine`. Edits mint a pipeline-owned replacement
and supersede the original; merges retain combined source evidence. Each
decision writes an immutable `GateDecision`, a content-safe hash-chain audit
event, a lifecycle event where state changes, and a replay-keyed validation
continuation.

## Human and machine surfaces

`/governance` is a password-session-only LiveView for account administrators
and curators. It exposes the queue, provenance/conflict IDs, individual
actions, edits, merges, and bulk decisions. Machine API keys cannot establish
that session, and `Cartulary.Policy.HumanRoleIn` prevents them from invoking
curator Ash actions directly.

Authenticated human peers use `/api/v1/self/knowledge` to inspect their subject
knowledge, contest or redact it, and request proportionate or strict erasure.
Machine credentials are rejected from these human-governance routes.
Erasure removes subject observations, knowledge and inline delivery text,
scrubs shared provenance in proportionate mode, removes all sourced knowledge
in strict mode, and marks/recomputes affected projections and entities.
Content-safe audit IDs, hashes, actions, and counts survive.

The AshAi MCP surface exposes only:

- `ingest`
- `get_context`
- `search`
- `ask`
- `query_knowledge`
- `resolve_validation`
- `set_ask_preference`

There are no curator tools. Read tools may attach at most one topically
relevant question for the calling peer. Attachment runs after the read under a
separate 15 ms task deadline; timeout, error, rate limit, or no match returns
the original read unchanged. Tests raise the deadline only to remove scheduler
timing from deterministic assertions.

`resolve_validation` treats the tool answer as a claim. Confirmation or
rejection changes knowledge only when an assistant transcript turn after
delivery contains the frozen statement text under NFKC/case/whitespace/quote
normalization. An unverified channel only defers the timer and can never grant
upward consent. Correction text is recorded as supplied evidence but cannot
mint knowledge through the MCP tool.

## Aging and recomputation

The existing revalidation, expiry, dream-time, validation-continuation, and
answer-correlation AshOban lanes now call real governance operations:

- due active knowledge becomes `needs_revalidation` and receives a peer query;
- expired knowledge becomes `expired`;
- overdue validation escalates once, then auto-rejects;
- unanswered peer queries decay confidence and become stale;
- verified confirmation resets the timer and raises confidence; and
- erasure recomputes or marks affected projections and entity derivations.

The same workflows and database guarantees run in pg0-backed single-node and
operator-run Postgres modes. Gate A/B governance introduces no alternate queue,
cache, or deployment implementation.

## `poc-0` transition

Baseline contract HTTP shapes, identity-derived tenancy, downward scope
inheritance, raw message durability, pipeline-only knowledge creation,
deterministic fallback, and eval fixture normalization remain regression
floors. The lifecycle semantics intentionally advance to `f4-1`: ingest records
`proposed → provisional` by default instead of the removed
`poc_auto_gate → active` shortcut, and health reports `f4-1`. Extractor and
retrieval profile versions remain `poc-0` at this checkpoint; that string is a
historical version tag and no longer names a roadmap phase. The model layer and
structured extraction subsequently advance extraction and health to `f5-1`;
retrieval, entity resolution, and context advance retrieval and context
profiles to `f7-1`.

## Evidence

- Resource migration:
  `priv/repo/migrations/20260727220024_f4_real_gate_a_b_governance.exs`
- Generated resource snapshots: `priv/resource_snapshots/repo/`
- Gate A/B governance acceptance suite:
  `test/cartulary/f4_real_gate_a_b_governance_test.exs`
- Updated baseline contract evidence:
  `test/cartulary/poc_contract_test.exs` and
  `test/cartulary_web/controllers/memory_controller_test.exs`
- Operation layer: `lib/cartulary/governance/`
- Human and self-service adapters: `lib/cartulary_web/`
