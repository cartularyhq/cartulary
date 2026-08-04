<!-- SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0 -->

# Retrieval, Entity Resolution, And Context

Status: implemented

Profile-selected, deadline-bounded strategies and projection-backed context
replace inline retrieval. This implements `FR-API-1` through `FR-API-5`, `FR-API-7`, `FR-API-10`,
`FR-API-23` through `FR-API-25`, `FR-API-27` through `FR-API-29`,
`FR-KN-18` through `FR-KN-22`, `AD-SEAM-3`, `AD-DATA-5`,
`AD-DATA-10`, `AD-PIPE-7`, `AINV-5`, `AINV-6`, and `NFR-2`.

## Retrieval boundary

`Cartulary.Retrieval.Strategy` defines `name/0`, `cost_class/0`, `stage/0`,
`applicable?/1`, and `candidates/2`. Cartulary ships:

| Stage | Strategies |
| --- | --- |
| Seed | Semantic, Lexical, Temporal, SalienceRecency, EntityMatch |
| Expand | RelationExpand |

Production seed strategies run concurrently; expansion then traverses knowledge
relations, permission-filtered scope relations, and shared-entity edges. SQL
sandbox tests run the same contracts serially on their shared connection.

Each source list has its own cutoff and cap. Weighted reciprocal-rank fusion
uses only within-strategy rank (`k = 60`), so pgvector similarity, FTS rank,
time relevance, salience, and mention confidence are never treated as
comparable scores. The `:thorough` profile optionally reranks only the fused
head through `Cartulary.Model.Gateway`. Reranking and grounded answers hold no
transaction; the model layer scopes its own configuration read and usage write.
A hard remaining-time budget wraps strategies and reranking. Reranking receives
an independently configured timeout clamped to the remaining hard deadline.
Timeouts are dropped, not retried, and every response preserves the compatible
dropped-name list while adding content-free component timings and deterministic
reason classes plus pre-fusion cross-strategy disagreement.

Query-independent strategies are applicability-gated: `Temporal` runs only
when the request supplies `as_of`; `SalienceRecency` runs only for a blank-text
governed-memory request. This keeps ordinary text-search heads
query-dependent, while explicit historical reads and context fallback retain
their intentional temporal and recency behavior. The profile memberships,
weights, response fields, and `f7-1` identity are unchanged; this is an
applicability correction recorded in ADR 0010.

The three strategy sets are disjoint and carry distinct facts: contributed
returned candidates, empty ran and matched nothing, dropped never produced a
result. Each strategy declares `query_dependent?/0` — true only for reading
`query.text`, so expansion inherits nothing from its seeds — and disagreement
reports `query_dependent_empty` when no such strategy contributed. That is the
FR-API-29 signal `strategy_count`, `disjoint`, and `low_score` cannot carry:
all three read only the lists that came back non-empty, so a strategy that
returned nothing leaves no trace in them, and a scope ranked by `temporal` and
`salience_recency` alone reports the same health as an answered query.

`candidates/2` returns candidates or `{:error, reason}`. The second means the
strategy never ran — an unavailable embedder, say — and the engine reports it
as dropped. An empty list keeps its own meaning: the strategy ran and matched
nothing. Collapsing the two would make a broken dependency indistinguishable
from an honest miss, which is the same confusion an unindexed corpus creates.

`Cartulary.Retrieval.Store` is the reviewed read-only data-layer helper for
the operations Ash does not express as ordinary resource reads: PG-FTS,
pgvector ANN order, hop-one expansion, content-free entity-cache aggregates,
and co-mention statement ids. Its static parameterized statements apply
Account, authorized scope, lifecycle, soft-delete, and caller-provisional
filters before returning content or a statement id. The aggregate query is
reachable only after the browser's account-admin gate and returns counts,
rates, and quantiles without entity identities. `Cartulary.Memory.Query` has
been removed. Durable writes remain Ash-action-only.

## Profiles and configuration

The built-in profile version is `f7-1`:

| Profile | Strategy posture | Rerank | Default surface |
| --- | --- | --- | --- |
| `:fast` | Semantic + SalienceRecency, one per request (ADR 0010) | No | `get_context` cache-miss fallback |
| `:balanced` | Semantic + Lexical + Temporal + EntityMatch | No | `search` |
| `:thorough` | All seeds + RelationExpand | Yes | `ask` and dream-time projection refresh |

An active `RetrievalProfile` on the nearest authorized scope overrides the
runtime profile. Its externally reported version combines the authored version
with a digest of strategies, weights, and rerank configuration. Deployment
configuration can constrain enabled strategy modules and the three deadline
ceilings through:

- `CARTULARY_RETRIEVAL_ENABLED_STRATEGIES`;
- `CARTULARY_RETRIEVAL_FAST_DEADLINE_MS`;
- `CARTULARY_RETRIEVAL_BALANCED_DEADLINE_MS`; and
- `CARTULARY_RETRIEVAL_THOROUGH_DEADLINE_MS`.
- `CARTULARY_RETRIEVAL_RERANK_TIMEOUT_MS`.

Raw strategy lists remain restricted to internal/system and eval callers.
Source filters are applied before fusion. `search` keeps the baseline-contract
shape by returning governed knowledge and document chunks in one candidate
collection distinguished by `candidate_type`; `ask` restricts its retrieval to
knowledge.

## Vector and lexical storage

Knowledge and document chunk embeddings are real PostgreSQL `vector` values,
not float-array stand-ins. Every vector retains provider, model, version, and
dimensions. The retrieval migration adds:

- HNSW cosine indexes for the pinned 384-dimensional knowledge, chunk, and
  entity collections;
- a generated document-chunk `tsvector` and GIN index;
- the existing knowledge-statement GIN index as the lexical path; and
- expansion lookup indexes for mentions and knowledge relations.

The production 384-dimensional semantic query uses the matching HNSW
expression. Other explicitly configured dimensions remain valid and use the
small-corpus path until their own reviewed index migration is installed.
`Cartulary.Retrieval.Vector` provides the deterministic Nx cosine baseline for
tiny eval corpora and entity candidate comparison. A pinned-identity mismatch
still follows the model layer's explicit re-embed plan; vectors are never
silently reused.

`projection_refresh` is the replay-safe rebuild job. It backfills knowledge
vectors, resolves entities, and refreshes projections. Document import already
re-enters ordinary document ingest, which rebuilds chunk vectors and causes
governed knowledge to enqueue the same derived-cache jobs.

Because vectors and mentions are written by that job alone and no longer ride
the knowledge-write transaction, they are eventually consistent: a refresh that
was cancelled or never enqueued leaves a scope holding every governed statement
with no vectors, while lexical search keeps answering from its generated
column. `Cartulary.Retrieval.Coverage` is the read that distinguishes the two —
per-scope statement, embedded, mention, and mentioned-statement counts plus the
embedding identities in use, under the same authorization and
provisional-subject rules as any other retrieval query. Mentions remain counts
so the entity cache stays internal. Every completed refresh emits
`[:cartulary, :retrieval, :projection_refresh]` with those counts and the
resulting ratio. The Account reconciler detects an active scope with no mention
rows and enqueues the same full refresh using a corpus-derived replay key.
Request-local diagnostics classify partial coverage and distinguish no resolved
entity from a resolved entity with no authorized statements without returning
cache identities or content.

`Indexer.rebuild_scope/2` and `EntityResolver.rebuild_scope/2` use a short read
transaction, connection-free model calls, and one final write transaction. The
entity resolver matches surface forms against an in-memory set seeded by the
read, including entities created earlier in the same run. Stale-mention removal
and replacement are atomic; any failure leaves the previous index intact.

## Entity resolution

`Entity` and `EntityMention` remain pipeline-internal derived resources
declared by the Ash domain backbone. The dream-time resolver processes active
governed statements using:

1. exact normalized alias matching;
2. Nx cosine over pinned alias embeddings; and
3. `dream_reasoner` structured adjudication only in the ambiguous band.

Unresolved mentions degrade retrieval coverage; they never block ingest.
Mentions inherit visibility exclusively from their knowledge statement.
EntityMatch returns statement candidates without entity rows, names, aliases,
surface forms, or entity ids. No Phoenix route, MCP resource, or public
resource action exposes the caches. Erasure removes affected mentions,
recomputes/prunes entities, and rebuilds affected projections. Logical import
excludes the cache and recreates it from governed statements.

Two diagnostic projections preserve that rule. `/console/operations` reports
Account-wide counts, an observed-alias histogram, singleton-entity rate, and
mentions-per-entity p50/p95 to a password-authenticated account administrator.
`/console/knowledge/:id` asks the store only for the count and capped ids of
co-mentioned statements after applying the reader's authorized scope and
console lifecycle filters, then loads those statements through the ordinary
Ash read policy. Neither path returns an entity or mention row to the web
layer.

## Context projections

`projection_refresh` runs `:thorough` retrieval at dream-time, then updates:

- one active-only scope card per scope;
- one entity card per scope/entity with at least three distinct active source statements;
- one peer profile slice per subject Peer/scope, containing active knowledge
  plus only that subject's provisional knowledge; and
- one active-only session summary per session.

Projection keys are Account-local and unique. Entity-card keys use a private
entity id only as a grouping coordinate; payloads expose no entity-cache field.
Cards carry the strictest source sensitivity, a bounded summary with model
provenance, and the governed source statements. Updates carry a watermark,
delta count, source ids, dirty state, and a bounded full-compaction cadence.
Lifecycle changes mark affected projections dirty and enqueue deterministic
entity/projection jobs in the same transaction as the state change.

Projection keys also carry a private audience-contract namespace. A stricter
stored-content rule advances that namespace, so nodes running the new code
cannot serve a clean projection written under the older rule while its rebuild
is pending. A miss uses the already subject-filtered `:fast` retrieval path.

`Cartulary.Context` reserves the caller's character budget in the required
order: session summary, peer profile, scope cards, entity cards, then
salience-ranked knowledge. Clean projections are cached in ETS. Invalidation is broadcast
through Phoenix PubSub so queue-mode nodes evict the same Account/scope key.
On a miss, and only on a miss, `get_context` uses the `:fast` retrieval profile.
It never invokes dialectic or dream reasoning on the live context path.

## Version and evidence

Message/extractor and health stay `f5-1`. Search, ask, and context advance from
`poc-0` to `f7-1`, with updated baseline HTTP evidence. These are historical
contract tags, not roadmap phases.

Implementation and regression evidence:

- retrieval and context code under `lib/cartulary/retrieval/` and
  `lib/cartulary/context/`;
- retrieval resource fields and actions in `lib/cartulary/knowledge.ex` and
  `lib/cartulary/documents.ex`;
- migration
  `priv/repo/migrations/20260728092147_f7_retrieval_entity_context.exs`;
- generated resource snapshots under `priv/resource_snapshots/repo/`;
- acceptance suite
  `test/cartulary/f7_retrieval_entity_context_test.exs`; and
- updated baseline-contract surface and document-vector regressions.
