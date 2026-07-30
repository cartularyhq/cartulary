<!-- SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0 -->

# Retrieval, Entity Resolution, And Context

Status: implemented

Retrieval, entity resolution, and context replace the earlier inline retrieval
helper with profile-selected, deadline-bounded candidate strategies and
projection-backed context assembly.
It implements `FR-API-1` through `FR-API-5`, `FR-API-7`, `FR-API-10`,
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

Seed strategies run concurrently in production. Expansion runs after the seed
head is known and traverses knowledge relations, permission-filtered scope
relations, and shared-entity edges. The test SQL sandbox deliberately runs the
same strategy contracts serially because one test owns one shared connection;
release/runtime execution retains `Task.async_stream` fan-out.

Each source list has its own cutoff and cap. Weighted reciprocal-rank fusion
uses only within-strategy rank (`k = 60`), so pgvector similarity, FTS rank,
time relevance, salience, and mention confidence are never treated as
comparable scores. The `:thorough` profile optionally reranks only the fused
head through `Cartulary.Model.Gateway`. That call is made with no transaction
open, as is grounded answer generation on the same request: the model layer
scopes its own configuration read and usage write, so wrapping either would
hold a pooled database connection across a provider call on a request that has
already finished reading. A hard remaining-time budget wraps both strategy
tasks and reranking. Timeouts are dropped, not retried, and every
response reports contributed and dropped strategies plus pre-fusion
cross-strategy disagreement.

`Cartulary.Retrieval.Store` is the reviewed read-only data-layer helper for
the operations Ash does not express as ordinary resource reads: PG-FTS,
pgvector ANN order, and hop-one expansion. Its static parameterized statements
apply Account, authorized scope, lifecycle, and caller-provisional filters
before returning content. `Cartulary.Memory.Query` has been removed. Durable
writes remain Ash-action-only.

## Profiles and configuration

The built-in profile version is `f7-1`:

| Profile | Strategy posture | Rerank | Default surface |
| --- | --- | --- | --- |
| `:fast` | Semantic + SalienceRecency | No | `get_context` cache-miss fallback |
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

## Context projections

`projection_refresh` runs `:thorough` retrieval at dream-time, then updates:

- one scope card per scope;
- one peer profile slice per subject Peer/scope; and
- one session summary per session.

Projection keys are Account-local and unique. Updates carry a watermark,
delta count, source ids, dirty state, and a bounded full-compaction cadence.
Lifecycle changes mark affected projections dirty and enqueue deterministic
entity/projection jobs in the same transaction as the state change.

`Cartulary.Context` reserves the caller's character budget in the required
order: session summary, peer profile, scope cards, then salience-ranked
knowledge. Clean projections are cached in ETS. Invalidation is broadcast
through Phoenix PubSub so queue-mode nodes evict the same Account/scope key.
On a miss, and only on a miss, `get_context` uses the `:fast` retrieval profile.
It never invokes dialectic or dream reasoning on the live context path.

## Version and evidence

The message/extractor and health identity remains `f5-1`. Search, ask, and
context profile identity intentionally advances from `poc-0` to `f7-1`; the
baseline HTTP evidence was updated for that explicit transition. These `f*`
prefixes are historical version tags and no longer name roadmap phases.

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
