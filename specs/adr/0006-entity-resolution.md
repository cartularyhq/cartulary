# ADR 0006: Entity resolution as a dream-time stage

## Status

Accepted. One sub-question is inherited from ADR 0004 and left open for the
maintainer: whether any retrieval strategy may be enterprise-gated (see the Open
question section).

This ADR adds two derived resources, one dream-time pipeline stage, and one
retrieval strategy. It adds nothing to the public API surface — the new
resources are deliberately unreadable through every external surface — so this
is not a breaking API change under ADR 0002. It amends ADR 0004's stage 4.

## Context

`FR-FORM-14` resolves each extracted statement against existing memory as one of
`add`, `merge`, `supersede-candidate`, or `no-op`. All four decisions are made
on statement similarity. None of them canonicalises *referents*: "Alice", "our
CTO", and `alice@example.com` are three unrelated strings to every part of the
system.

Three consequences follow, and all three are currently invisible because nothing
measures them.

`merge` (`FR-KN-9`) is weaker than it reads. Two statements about the same
person phrased differently are near-duplicates only if the embedding happens to
bring them together; the system has no notion that they share a subject.

`Lexical` carries proper nouns only when spelled identically. This is the
strategy specifically justified in ADR 0004 as the one that "carries exact
tokens, identifiers, and proper nouns that embeddings blur", and it fails on the
most common way proper nouns actually vary: by alias, not by spelling.

Multi-hop questions have no traversal path. `RelationExpand` hops over
`supersedes`, upkeep links, and `ScopeRelation` — all structural edges. Nothing
connects two statements because they are about the same thing.

The field has converged on this being a distinct pipeline stage. The current
survey describes agent-memory ingestion as Extract → **Resolve** → Store →
Index, and names entity matching as a third retrieval signal alongside semantic
and lexical. The more useful datum is Mem0's: they *replaced* external graph
databases with graph-style entity linking and kept the multi-hop improvement
(+23.1 on their reported multi-hop measure). That is evidence the traversal
benefit ADR 0004 stage 4 was reaching for does not require a knowledge graph.

For Cartulary the gating constraint makes this asymmetry sharper still.
`FR-KN-2` stores natural-language statements only, so that a human gates one
statement rather than forty triples. A knowledge graph therefore has to be
derived at dream-time from already-validated statements, inheriting each parent
statement's gate — expensive, and the derived structure is large relative to
what it buys. An entity index is derived under exactly the same constraint and
is far smaller: one canonical referent per real-world thing, plus an annotation
per mention.

## Decision

### Two derived resources

`Cartulary.Knowledge.Entity`:

| Field | Purpose |
|---|---|
| `account_id` | Tenancy (`AINV-6`) |
| `canonical_name` | Preferred surface form |
| `kind` | `:person \| :org \| :system \| :artifact \| :concept` |
| `aliases` | Observed surface forms |
| `alias_embedding` | Vector over canonical name and aliases; candidate lookup |
| `derived_from` | Statement ids the entity was resolved from |

`Cartulary.Knowledge.EntityMention` joins them to knowledge:
`statement_id`, `entity_id`, `surface_form`, `confidence`.

### Entities carry no visibility of their own

Entities are account-global, following the Peer precedent (`AD-SEC-2`).
Mentions inherit scope from the statements they annotate, and retrieval
continues to filter statements by scope and policy exactly as before.

This yields the property the rest of the design depends on: **entity resolution
cannot change who can read what.** A resolution error costs accuracy. It cannot
breach the account wall (`AD-SEC-1`, `AINV-6`) or a scope boundary, because
neither is enforced at the entity layer and neither consults it.

Two constraints keep that true, and both are load-bearing rather than
housekeeping:

**Entities are not readable through any public surface.** No REST, MCP, SDK, or
LiveView endpoint returns entity rows, alias lists, or canonical names. An
entity resolved from a statement in a restricted scope would otherwise expose a
referent name past the statement-level filter that is doing all of the security
work — a canonical name is itself information, and it is derived from content
the caller may not be entitled to. Entities exist solely as a retrieval-internal
index. This is asserted by a test in the deterministic PR gate (`AD-EVAL-3`),
not left to review discipline, because it is a rule and rules erode.

**Erasure recomputes entities.** `FR-GOV-15` and `FR-GOV-16` must recompute
every entity whose `derived_from` set included an erased statement, pruning any
entity left with no surviving source. Because entities are a derived cache this
is recomputation rather than deletion, but it does not happen by itself and must
be wired into the erasure flow alongside the existing projection recompute.

### `FR-KN-2` is preserved, not weakened

An entity is a canonical referent, not a triple. Statements remain
natural-language and human-validatable; mentions are annotations over them. No
structured knowledge representation enters the system, and no human is asked to
gate anything other than a statement.

This is the distinction that lets entity resolution ship while the
knowledge-graph layer stays deferred. It is worth stating explicitly because the
two look adjacent and are not: a graph asserts *relationships between things* as
content, an entity index asserts only *that two mentions denote the same thing*.

### Placement: dream-time

Three reasons, in order of force:

1. **Gating.** Entities derive only from already-validated statements,
   inheriting the parent statement's gate — the same constraint the deferred
   graph layer carries, for the same reason.
2. **Ingest is reasoning-free.** `AD-PIPE-2` admits extraction and cheap gating
   only. Resolution is reasoning.
3. **Resolution needs corpus context.** Ingest is per-message; resolution needs
   the candidate entity set.

Accepted consequence, recorded so it is not discovered as a bug: statements
pending a gate carry no entity links, so `EntityMatch` cannot retrieve them.
This is consistent with the rest of the system — pending statements are not
retrievable as knowledge by any path.

### Resolution cascade

Cheap first; the expensive step runs only where the cheap ones are ambiguous.

1. Exact alias match.
2. Alias-embedding similarity above a configured match threshold.
3. Dream-reasoner adjudication (`AD-MODEL-1` capability behaviour), for the band
   between the match threshold and the reject threshold only.

Step 3 runs under the dream-time token budget and is shed first under pressure
(`AD-PIPE-3`, `AD-PIPE-4`), so the degradation mode is unresolved mentions
rather than a stalled lane — consistent with `AD-PIPE-9`.

### Derived cache, under `AINV-5`

`Entity` and `EntityMention` are rebuildable from statements and are never the
system of record. They are excluded from the `AD-PORT-1` logical export and
regenerate on import; the export manifest already carries the embedder model and
version, which is what a rebuild needs.

This is what makes entity correction cheap. A merge or split is recomputation,
not history rewriting: it needs no governance gate, leaves no ledger entry, and
cannot desynchronise from the statements it derives from.

### The `EntityMatch` retrieval strategy

A new `Cartulary.Retrieval.Strategy` implementation under ADR 0004's seam:

- `name/0` — `:entity_match`
- `cost_class/0` — `:cheap`
- `stage/0` — `:seed`
- `applicable?/1` — true when the query contains a mention resolvable against
  the account's entity set
- `candidates/2` — statements mentioning the resolved entities, ranked by
  mention confidence combined with the statement's own score

It fuses through RRF like every other strategy, so a misfiring `applicable?/1`
adds low-ranked candidates rather than wrong answers — the bounded failure mode
ADR 0004 identifies as the reason strategies are safe to add.

`RelationExpand` gains a second edge type: hop-1 expansion may traverse
shared-entity edges alongside `supersedes`, upkeep links, and `ScopeRelation`.

Profile placement: `EntityMatch` joins `:balanced` and `:thorough`. It stays out
of `:fast`, which exists to serve a `get_context` cache miss and must stay
minimal.

### ADR 0004 stage 4 is retargeted

ADR 0004's staging ends with "dream-time knowledge graph and the `Graph`
strategy". That stage becomes **entity graph and `EntityMatch`**.

The full knowledge-graph layer stays deferred (ARCH §18, FR §12) and may never
be needed: the multi-hop gain it was staged for appears to be available from
entity linking at a fraction of the derived-structure cost. The `Graph` seam
stays reserved; nothing here forecloses it.

## Consequences

Deduplication gets a signal it did not have. `FR-KN-9` merge decisions can
consult referent identity rather than inferring it from embedding proximity.
This is the change most likely to improve quality in ways the conversation
benchmarks will not show, because it affects what is stored rather than what is
retrieved.

Retrieval gains a cheap seed strategy on the two profiles that can afford it.
Expected to help most on the query shapes where semantic blurs and lexical
misses — questions naming a person or system by an alias the corpus does not
use verbatim.

The dream-time lane gets another stage. Budget-capped and shed first, so the
failure mode is unresolved mentions and staler entity coverage, never a stalled
queue.

Resolution errors are a new class of accuracy bug. Two distinct referents merged
into one entity produces retrieval that confidently mixes them. Mitigated by a
conservative threshold, by adjudication of the ambiguous band, and by
recomputability — but the containment property above is what bounds it: the
blast radius is answer quality, never disclosure.

A rule now guards a security-adjacent boundary. "Entities are never publicly
readable" is enforced by a PR-gate test rather than by structure. That is weaker
than the account wall's defence-in-depth and is called out as such; the
compensating factor is that the rule is simple enough to test exhaustively —
no public surface returns these two resources, ever.

## Staging

**Stage 1 — resolution without retrieval.** `Entity`, `EntityMention`, and the
dream-time cascade, with no retrieval strategy. Entity coverage and resolution
precision become measurable before anything depends on them.

**Stage 2 — the `FR-KN-9` merge signal.** Referent identity feeds
`FR-FORM-14`'s `merge` decision. Measured against the ADR 0004 Stage 0 baseline.

**Stage 3 — `EntityMatch`.** The strategy, in `:balanced` and `:thorough`,
ablated through the ADR 0004 harness before the default profiles change.

**Stage 4 — shared-entity edges in `RelationExpand`.**

Stage 1 must not start before ADR 0004's Stage 0 baseline exists, for the reason
ADR 0004 gives: without it there is nothing to attribute improvement to.

## Open question

**May `EntityMatch` be enterprise-gated?** Inherited from ADR 0004's open
question rather than reopened here. The recommendation is unchanged — no; gate
scale, operations, governance, and support, not answer quality. Licensing
boundaries are an ADR 0002 human-only decision area.

## Anchors

- `AINV-5` - system of record vs derived cache; entities are a cache.
- `AINV-6` - account derived from identity; entity tenancy.
- `AINV-8` - domain strategies vs infrastructure ports; `EntityMatch` is domain.
- `AD-SEAM-3` - domain strategies; gains `EntityMatch`.
- `AD-DATA-10` - entities and mentions as a derived, non-exported cache.
- `AD-SEC-1` - the hard account wall; unaffected by entity resolution.
- `AD-SEC-2` - peer identity model; the account-global precedent.
- `AD-MODEL-1` - capability behaviours; the adjudication step.
- `AD-PIPE-2` - ingest is reasoning-free; why resolution is dream-time.
- `AD-PIPE-3` / `AD-PIPE-4` - dream-time budgets; the shed-first cascade step.
- `AD-PIPE-9` - read/write cost asymmetry; why the stage sits on the write side.
- `AD-PORT-1` - logical export; entities are excluded and regenerate.
- `AD-EVAL-3` - PR gate hosts the no-public-entity-surface test.
- `FR-KN-2` - natural-language statements only; preserved, not weakened.
- `FR-KN-9` - dedup and merge; gains referent identity as a signal.
- `FR-KN-18`..`FR-KN-22` - entity resolution requirements.
- `FR-FORM-14` - update-operation resolution; `merge` gains the signal.
- `FR-GOV-15` / `FR-GOV-16` - erasure; must recompute entities.
- `FR-API-25` - multi-strategy retrieval; gains `entity_match`.

## Related Documents

- `specs/adr/0002-l3-automation-boundary.md`
- `specs/adr/0004-multi-strategy-retrieval.md`
- `specs/design/2026-07-27-research-informed-design-improvements.md`
- `specs/memory-system-architecture-and-nfr.md`
- `specs/memory-system-functional-requirements.md`
