# ADR 0004: Multi-strategy retrieval with deadline-bounded fusion

## Status

Accepted. One sub-question is left open for the maintainer: whether any
retrieval strategy may be enterprise-gated (see the Open question section).

**Amended by ADR 0006** (`docs/adr/0006-entity-resolution.md`): the strategy set
gains `EntityMatch`, `RelationExpand` gains shared-entity edges, and Stage 4 is
retargeted from the knowledge graph to the entity graph. Amendments are marked
in place below.

This ADR adds retrieval query parameters and a named-profile concept to the
public surface. Both are additive, so this is not a breaking API change under
ADR 0002. The licensing sub-question *is* an ADR 0002 human-only decision area
and is therefore recorded as open rather than decided here.

## Context

`AD-SEAM-3` currently names a single `RetrievalStrategy` behaviour that wraps
"hybrid semantic + BM25/FTS fusion with optional rerank". That is one seam
carrying three different jobs: generating candidates, merging ranked lists, and
reranking a head. Because they are conflated, none of them can be varied,
measured, or ablated independently. Adding a fourth way to find a candidate
means editing the hybrid implementation rather than adding a module.

Hindsight, the closest comparable system, runs four concurrent retrieval
strategies — semantic, keyword/BM25, graph, and temporal — followed by
cross-encoder reranking, and reports 94.6% on LongMemEval in a typical
100–600ms band. Whatever the self-reported number is worth, the structural claim
is credible and worth copying: different query shapes are served by different
retrieval mechanisms, and running several cheap ones concurrently costs little
more than running the slowest.

Two facts about Cartulary make this cheaper for us than it sounds.

First, the temporal strategy is nearly free. Tri-temporal data is already stored
and already indexed: belief-time intervals (`FR-KN-17`), valid-time `expires`,
the salience relevant-window, and `as_of(D)` as an indexable interval filter
(`FR-API-23`, `AD-DATA-1`). Hindsight's fourth strategy is data we index and
never query *as a strategy*. The cost is one indexed range scan.

Second, since ADR 0003 there is one data layer. Every strategy runs against the
same Postgres over the same connection, so fan-out is concurrent queries on one
pool rather than a scatter-gather across heterogeneous stores.

The BEAM contributes the mechanism that makes fan-out safe: `Task.async_stream`
with `on_timeout: :kill_task` gives a hard wall-clock bound on the whole set,
independent of how many strategies are in it.

The latency question needs care. Hindsight's 100–600ms band sits *between*
Cartulary's two read paths. `get_context` targets ~100ms and is reasoning-free
(`NFR-1`, `NFR-2`); `ask` and `search` have no `NFR-1` target and are reported
separately. Their evidence does not show that four strategies plus a
cross-encoder fit in 100ms. It shows they fit in a few hundred. So multi-strategy
retrieval belongs on `ask`/`search`, and `get_context` must earn its quality some
other way.

## Decision

### One seam becomes three

`AD-SEAM-3`'s retrieval seam splits into three named seams:

1. **Candidate generation** — N `Cartulary.Retrieval.Strategy` modules, each
   producing a ranked candidate list independently.
2. **Fusion** — merging N ranked lists into one.
3. **Rerank** — an optional, expensive precision pass over the fused head. This
   is the existing `Reranker` capability behaviour from `AD-MODEL-1`, not a new
   one; ADR 0004 only fixes where it sits in the pipeline.

The other three domain strategies named in `AD-SEAM-3` — the gate/auto-accept
matrix, chunking, and model-tiering — are unaffected.

### The strategy behaviour

```elixir
defmodule Cartulary.Retrieval.Strategy do
  @callback name() :: atom()
  @callback cost_class() :: :cheap | :moderate | :expensive
  @callback stage() :: :seed | :expand
  @callback applicable?(Query.t()) :: boolean()
  @callback candidates(Query.t(), Budget.t()) ::
              {:ok, [Candidate.t()]} | {:error, term()}
end
```

A `Candidate` carries `id`, `score`, `rank`, `strategy`, and `evidence`. The
score is strategy-local and **not comparable across strategies** — this is the
constraint that determines the fusion choice below. A `Budget` carries
`deadline_ms`, `started_at` (from the injected clock, `AD-EVAL-4`), and
`max_candidates`.

`applicable?/1` makes each strategy self-gating. There is no central query
planner deciding which strategies to run; a strategy inspects the query and
declines. This keeps the decision next to the code that understands it and
avoids a planner that must be updated every time a strategy is added.

`stage/0` records a structural fact that Hindsight's four-parallel-boxes diagram
hides: **not all strategies are parallel-independent.** Relation expansion needs
seeds to expand from. So retrieval runs in two phases — all `:seed` strategies
concurrently, then all `:expand` strategies concurrently over the union of the
seed heads — and the wall clock is seed-deadline plus expand-deadline, not one
deadline.

### The strategies

- **`Semantic`** — pgvector ANN over the embedding column. Seed.
- **`Lexical`** — PG-FTS/BM25. Seed. Carries exact tokens, identifiers, and
  proper nouns that embeddings blur.
- **`Temporal`** — indexed interval filter over belief-time, valid-time, and
  relevant-window, honouring `as_of`. Seed. Cheapest strategy we have and the
  one with the highest expected benchmark points per millisecond, because
  LongMemEval's temporal-reasoning and knowledge-update categories are exactly
  what it addresses.
- **`SalienceRecency`** — ranks on the precomputed salience × durability ×
  recency terms of the `FR-API-10` scoring function. Embedding-free, so it works
  when there is no query embedding yet. Seed.
- **`RelationExpand`** — hop-1 over `supersedes`, A-MEM upkeep links, and
  `ScopeRelation` edges from the seed head. Expand.
- **`Graph`** — deferred, over the dream-time knowledge graph. Seed or expand
  depending on the query; the seam is reserved, the module is not written.
  *Amended by ADR 0006:* no longer attached to a stage — stage 4 is retargeted
  to the entity graph.
- **`EntityMatch`** — *added by ADR 0006.* Statements mentioning the canonical
  entities a query's surface forms resolve to, ranked by mention confidence
  combined with the statement's own score. Cheap, seed, in `:balanced` and
  `:thorough`. `RelationExpand` gains shared-entity edges alongside its
  structural ones.

### Fusion is reciprocal rank fusion

`score(d) = Σ_s w_s / (k + rank_s(d))`, with `k = 60` and per-strategy weights
`w_s` from configuration.

The reason is the score-incomparability constraint above. Cosine similarity, BM25
scores, and interval-overlap measures live on different scales with different
distributions. Score-based fusion requires calibrating them against each other,
and that calibration has to be re-derived whenever an embedding model, an
analyzer, or a corpus changes. RRF needs none of it: it uses only within-strategy
rank order, which is the one thing every strategy produces meaningfully.

RRF's cost is that it discards magnitude. A strategy returning 100 weak
candidates contributes the same rank-1 weight as a strategy returning three
strong ones. The mitigation is at the source, not in the fusion: every strategy
has a `min_score` cutoff and a `max_candidates` cap, so a strategy that finds
nothing good returns nothing rather than noise.

### Deadline-bounded fan-out

Each phase runs its strategies through `Task.async_stream` with
`on_timeout: :kill_task` and `ordered: false`. Fusion runs over whichever
strategies returned before the deadline. A strategy that times out is dropped —
not retried, not fatal.

This is the property that makes the design safe to extend: **adding a strategy
cannot blow the latency budget, only change what fills it.** The budget is
enforced by the harness, not by the discipline of each strategy author.

Every response reports which strategies contributed and which were dropped. That
is both an operational signal and the input to the ablation harness below.

The cost is nondeterminism: under load, the same query can fuse a different
strategy set. The eval harness therefore runs with deadlines disabled (or with a
fixed deadline against a fake clock, `AD-EVAL-4`). Without that, benchmark scores
would vary with CI machine load, which would make them useless as a regression
signal.

### Named, versioned profiles

A profile is a strategy set plus weights plus rerank on/off.

- **`:fast`** — `Semantic` + `SalienceRecency`, no rerank. Live fallback for a
  `get_context` cache miss.
- **`:balanced`** — `Semantic` + `Lexical` + `Temporal`, RRF, no rerank. Default
  for `search`.
- **`:thorough`** — all seed strategies + `RelationExpand` + cross-encoder
  rerank. Default for `ask`.

Profiles are **versioned**. A quoted benchmark number that does not cite a
profile version is not reproducible, and reproducible numbers are the whole point
of the eval app.

### Selection is layered in three places

This maps onto `AD-CFG-1`'s existing two-kinds split:

1. **`config/runtime.exs`** (infra) — which strategy modules are enabled at all
   on this deployment, and the deadline ceilings.
2. **DB policy config, scope-level nearest-wins inheritance** (policy) — default
   profile and fusion weights per scope, at the same grain as visibility and
   RBAC.
3. **Per-query** — `retrieval_profile: :fast | :balanced | :thorough`.

A raw `strategies: [...]` list is also accepted, but is restricted to internal
and eval callers. Exposing internal module names on the public API would freeze
them into the contract, and we want to be able to rename, merge, and delete
strategies.

### `get_context` stays a projection read

`get_context` does **not** fan out. It remains a read of materialised
projections (`AD-DATA-3`) served from ETS/`persistent_term`, exactly as `NFR-2`
describes.

Multi-strategy retrieval serves `get_context` by running at **dream-time, to
build those projections**. The expensive strategies, the reranker, and the graph
all run in the slow lane where the budget is measured in seconds; what lands in
the projection is their output. Pay offline, serve online.

This is the same bet the architecture already makes with the fast-lane /
slow-lane split, applied to retrieval. It is also the only honest answer to
"high benchmark accuracy under a hard 100ms budget": you do not run a
cross-encoder in 100ms, you run it earlier.

### Abstention gets a new input, not a new mechanism

`AD-MODEL-3` already enforces grounding and abstention structurally against
`FR-API-26`: cited ids must have been retrieved in-loop, absent or
`expired`/`needs_revalidation` knowledge is surfaced as unknown-or-stale, and
"insufficient memory" is a first-class schema-valid outcome. None of that
changes.

What ADR 0004 adds is a signal and a warning.

The signal: **cross-strategy disagreement**. When semantic, lexical, and temporal
each surface disjoint candidate sets with low raw scores, that is evidence the
corpus does not contain the answer — stronger evidence than any single
strategy's score, because the failure is corroborated by independent mechanisms.
Combined with confidence-at-read (`AD-DATA-2`), it feeds the existing abstention
decision.

The warning: **abstention must be computed pre-fusion.** RRF always produces a
ranked list, including from three lists of garbage. A fused rank carries no
information about whether anything was actually found. Any abstention logic
reading the fused output is reading a number that cannot say no.

## Consequences

Retrieval becomes ablatable. Each strategy is a module with a behaviour, so the
eval app can run benchmark × strategy-set × profile with deadlines disabled and
report per-category scores. That is the evidence for the default profile weights,
and it replaces argument about which strategies matter with measurement.

A wrongly-enabled strategy costs latency, not correctness. Strategies are
additive and fusion is rank-based, so an `applicable?/1` misfire adds candidates
that RRF ranks low. This is a genuinely good property: the failure mode of the
gating logic is bounded and cheap.

The read path gains moving parts. Mitigated by each strategy being independently
testable, self-gating, and droppable at the deadline, but it is real: there are
now more ways for retrieval to be subtly wrong, and more surface for the ablation
harness to have to cover.

Fusion weights can overfit. Tuning `w_s` against LongMemEval and LoCoMo will
produce weights that flatter those benchmarks. The mitigations are a held-out
set that never informs tuning, and the fact that weights are configuration rather
than code, so a deployment with a different corpus shape can retune without a
release.

Benchmark numbers acquire a required citation. Any published score must name the
profile version and say whether deadlines were enabled. Slightly more friction in
marketing copy; considerably more credibility.

The dream-time lane gets more expensive. Building projections with the thorough
profile plus reranking costs more slow-lane budget per write. This is
budget-capped and shed first, as the pipeline already specifies, so the failure
mode is staler projections rather than a stalled queue.

## Staging

**Stage 0 — baseline before strategies.** Run LongMemEval and LoCoMo through the
real API surface and record per-category scores with the current hybrid path. No
strategy work starts until this number exists, because otherwise there is nothing
to attribute improvement to.

**Stage 1 — `Temporal`.** Cheapest strategy, data already indexed, and it targets
the categories the baseline is most likely to be weak in.

**Stage 2 — self-gating and `RelationExpand`.** `applicable?/1` across the seed
strategies, then hop-1 expansion, which introduces the two-phase deadline.

**Stage 3 — rerank on `ask` and `search`.** Cross-encoder via `AD-MODEL-1`'s
`Reranker`, on the fused head only, in the `:thorough` profile.

**Stage 4 — ~~dream-time knowledge graph and the `Graph` strategy~~ entity graph
and `EntityMatch`.** *Retargeted by ADR 0006.* The stage is now entity
resolution and the `EntityMatch` seed strategy: canonical referents derived at
dream-time from already-validated statements, one entity per real-world thing
plus an annotation per mention. Same gating constraint as the original stage,
far less derived structure.

The knowledge-graph layer stays deferred with no stage attached (ARCH §18, FR
§12). The constraint that shaped it is unchanged and still worth recording:
Cartulary cannot do Hindsight's write-time KG construction, because `FR-KN-2`'s
natural-language-statement-only rule exists so a human can gate one statement
rather than forty triples, and the derived graph must stay a derived cache under
`AINV-5`. What changed is the evidence that the multi-hop gain this stage was
reaching for does not require the graph at all — Mem0 replaced external graph
databases with graph-style entity linking and kept the improvement. The `Graph`
seam stays reserved.

## Open question

**May any retrieval strategy be enterprise-gated?** The expensive strategies —
rerank, graph — are the ones with obvious commercial appeal, and gating them is
the obvious monetisation.

The recommendation is **no**. Gating retrieval quality breaks `AINV-1`'s
identical-guarantees directive in the place users would most notice, and it
undermines the free-tier credibility that ADR 0003 was largely about. Gate scale,
operations, governance, and support — not answer quality.

Licensing boundaries are an ADR 0002 human-only decision area, so this stays open
for the maintainer rather than being settled here.

## Anchors

- `AINV-1` - identical guarantees; retrieval quality should not vary by edition.
- `AINV-5` - system of record vs derived cache; the dream-time KG is a cache.
- `AINV-8` - domain strategies vs infrastructure ports; strategies are domain.
- `AD-SEAM-3` - domain strategies; the retrieval seam splits into three.
- `AD-SEAM-4` - cross-port invariants.
- `AD-DATA-1` - tri-temporal model; the basis of the `Temporal` strategy.
- `AD-DATA-2` - confidence computed at read; an abstention input.
- `AD-DATA-3` - materialised projections; what dream-time retrieval builds.
- `AD-DATA-5` - vector + lexical co-located; why fan-out is one pool.
- `AD-MODEL-1` - capability behaviours; `Reranker` becomes the rerank seam.
- `AD-MODEL-3` - grounding & abstention; gains an input, keeps its mechanism.
- `AD-PIPE-2` - fast lane vs dream-time slow lane.
- `AD-CFG-1` - two kinds of config; profile selection layers onto both.
- `AD-EVAL-2` - testing pyramid; strategy-level contract tests.
- `AD-EVAL-4` - injected clock; required for deterministic eval runs.
- `AD-EVAL-5` - in-repo eval app; hosts the ablation harness.
- `NFR-1` - latency targets; `ask`/`search` band vs `get_context`.
- `NFR-2` - how `get_context` hits its target; unchanged, and that is the point.
- `FR-API-6` / `FR-API-7` - `ask` and `search` profile defaults.
- `FR-API-10` - context-assembly scoring; the `SalienceRecency` strategy.
- `FR-API-23` - `as_of`; the `Temporal` strategy.
- `FR-API-25` - hybrid retrieval; becomes multi-strategy with named profiles.
- `FR-API-26` - grounding & abstention.
- `FR-KN-2` - natural-language statements only; why the KG is dream-time.
- `FR-KN-17` - belief-time intervals.

## Related Documents

- `docs/adr/0002-l3-automation-boundary.md`
- `docs/adr/0003-embedded-postgres-pg0.md`
- `specs/memory-system-architecture-and-nfr.md`
- `specs/memory-system-functional-requirements.md`
- `specs/memory-system-product-blueprint.md`
