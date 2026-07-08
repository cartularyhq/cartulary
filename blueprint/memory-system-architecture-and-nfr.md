# Cartulary — Multi-Scope Agent Memory System — Architecture & Non-Functional Requirements

> **Edition:** **Elixir/Ash edition.** This document supersedes the TypeScript edition for the *how-it's-built* layer. The **product semantics, invariants, gates, temporal model, and NFR envelope are unchanged** — only the implementation platform changes: TypeScript/Node → **Elixir/BEAM**, hand-rolled ports-and-adapters → **Ash Framework** (Domains, Resources, Actions; data layers *are* the adapters), Redis/BullMQ → **Oban** (via **AshOban**), Node HTTP surfaces → **Phoenix** (HTTP + LiveView + Channels). Every `AD-*`, `NFR-*`, and `AINV-*` anchor from the TypeScript edition is retained as a stable review handle; the prose under it is rewritten for the new platform. Where a section changes materially, a **`**Changed from the TypeScript edition:**`** line records the delta.
>
> **Status:** v1.0 — final. Companion to `memory-system-functional-requirements.md` (the **FR spec** v1.0 — *what* the system does) and `memory-system-evaluation-framework.md` (the **EV spec** — *how it is validated*). This document is the **architecture and NFR layer**: *how the system is built* so that one codebase runs unchanged on a laptop and as a multi-region cluster, with identical guarantees.
> **Product name:** **Cartulary** (resolved; was an open decision in v0.1 — see §18). *Multi-Scope Agent Memory System* remains the descriptive subtitle.
> **Anchors:** architecture decisions are prefixed **`AD-<AREA>-<n>`**; non-functional targets **`NFR-<n>`**; architecture invariants **`AINV-<n>`**. References of the form `FR-XXX-n` point into the FR spec, `EV-XXX-n` into the EV spec, `INV-n` into an FR invariant (FR §10), `[n]` into the references (§19). Anchors are stable for review and traceability.
> **Prime directive:** *one codebase, two deployment modes, identical guarantees.* Single-node and queue-mode are the same artifacts with different adapters wired in — never a fork, never a "lite" reimplementation. Almost every decision below follows from this. On BEAM the two modes converge further than they did on Node: single-node is one supervised OS process, queue-mode is *N identical clustered nodes* — never a different set of programs.
>
> **Changelog v0.1 → v1.0:** all FR references now resolve against FR v1.0 (FR-KN-17, FR-API-23/24/25/26, FR-GOV-21, FR-PLAT-15/16 were added there); terminology unified on **dream-time** for the slow reasoning lane (previously also called "background processing"); added **AD-PIPE-7** (incremental projection refresh — anti-context-collapse), grounding & abstention wired into **AD-MODEL-3** (FR-API-26), named public benchmarks as the §15 replay targets; research grounding added inline and in §19. No structural decisions changed.

---

## Table of contents

1. Purpose & how to read this document
2. Architecture invariants
3. Language, runtime & repository topology
4. Component decomposition & internal seams
5. Deployment topology & process model
6. Data & storage architecture
7. Asynchronous pipeline & job orchestration
8. Model & provider abstraction
9. API surfaces & contracts
10. Headless governance & interaction channels
11. Security, identity & tenancy
12. Observability & metering
13. Configuration, packaging, distribution & licensing
14. Portability & migration
15. Quality & evaluation architecture
16. Non-functional targets, SLOs & resilience
17. Recommended technology stack (concrete)
18. Open & deferred decisions
19. References

---

## 1. Purpose & how to read this document

The FR spec defines the system's behaviour as a set of numbered requirements. This document defines the **structure** that delivers that behaviour and the **non-functional envelope** it must hold. Each section states the decisions for one area as numbered `AD-*` entries — *decision, rationale, traceability* — in the spirit of an ADR log, so a contributor can see not just what was chosen but why, and against which requirement.

**Architecture at a glance.** The core loop is **observe → extract (fast) → reason (dream-time) → gate → project → serve**. Agents and connectors submit raw observations through an edge surface; a cheap extractor mints *proposed* knowledge at ingest-time; a stronger periodic dream-time reasoner deduces, reconciles conflicts, levels by corroboration and refreshes projections; humans validate at the gates (via a console or their own chat channels); agents consume precomputed, reasoning-free context. This split — pay for reasoning offline, serve precomputed state online — is the system-level application of the sleep-time-compute result [4]. The system is **I/O-bound orchestration** — the heavy compute (embeddings, inference) lives in external model endpoints or in a dedicated native NIF tier — which shapes the language choice (§3) and the latency posture (§16). The same modules deploy as a single in-process release or as a horizontally-scaled cluster, distinguished only by which data layers and queue engine are wired and whether clustering is enabled.

**Changed from the TypeScript edition:** the runtime is the **BEAM**. Its scheduler, in-process message passing, and supervision trees make "I/O-bound orchestration with heavy fan-out and background reasoning" the platform's native workload rather than something assembled from a queue, a worker pool, and an RPC layer. The conceptual loop and the online/offline compute split are unchanged.

---

## 2. Architecture invariants

These are the non-negotiable structural anchors. Every `AD-*` is consistent with them; they parallel the FR spec's §10. **They are unchanged from the TypeScript edition** — they are product/architecture invariants, not platform choices.

- **AINV-1 — One codebase, two modes, identical guarantees.** Single-node and queue-mode are the same release image with different data layers and queue engine wired; there is no fork and no capability divergence beyond what the licence gates. On BEAM this is sharper: both modes run the *same* supervision tree; queue-mode merely enables clustering and points the Ash data layer + Oban engine at Postgres.
- **AINV-2 — The user owns the data and the keys.** Bring-your-own database, cloud, and model key; a logical, backend-agnostic export exists for every account. No proprietary managed service is a hard dependency on the core path.
- **AINV-3 — Don't reinvent wheels.** Every subsystem first asks which mature library owns the problem before any code is written. On this platform that means Ash (domain/persistence/policy/multitenancy), Oban (jobs), Phoenix (surfaces), and a deliberate Rust/C NIF tier (parse/embed/ANN) before any bespoke code.
- **AINV-4 — Edition split without a fork.** Free core and enterprise features live in one umbrella project, gated at runtime; the community edition always builds in isolation.
- **AINV-5 — System of record vs derived cache.** The durable stores are raw messages, validated knowledge, and the audit log. The queue (Oban jobs), the vector/lexical indices, the HNSW index, ETS/`persistent_term` caches, and the projections are derived caches, rebuildable from those stores. Losing a cache is a timeliness problem; losing a store is data loss.
- **AINV-6 — Account is derived from identity, never from a request parameter.** The hard isolation boundary is enforced upstream of any handler (Phoenix plug / Ash `actor` + `tenant`) and re-checked in depth (Ash policies + DB RLS); cross-account access is structurally impossible.
- **AINV-7 — Two integration paths.** The asynchronous write/pipeline path integrates through the durable substrate (Oban job in the same DB transaction as the write), never through direct service-to-service RPC. The synchronous heavy-read path fans out across the BEAM (`Task.async_stream`, across the cluster only if needed). Different needs, different mechanisms.
- **AINV-8 — Infrastructure ports vs domain strategies.** Swapping an infrastructure adapter (an Ash data layer, a blob store, a secrets backend) changes *where* data lives, never *what the system does*; swapping a domain strategy (a behaviour implementation) changes *behaviour*. The two are never conflated behind one abstraction.

---

## 3. Language, runtime & repository topology

**Changed from the TypeScript edition:** the language is **Elixir on the BEAM**, and the hand-built layered package graph (`shared → ports → adapters → core → surfaces → apps`, enforced by `dependency-cruiser`) largely *collapses onto Ash*. Ash Domains group Resources; Ash data layers are the storage/vector/lexical adapters; Ash Actions are the typed op layer. The conceptual seams survive as Ash extension points and Elixir behaviours; the bespoke plumbing does not.

- **AD-LANG-1 — Elixir, single language, end to end for the engine.** Rationale: the system is I/O-bound orchestration with heavy fan-out, soft-real-time reads, and long-running background reasoning under multi-tenant isolation — precisely the BEAM's sweet spot. The scheduler gives cheap concurrency for the `ask`/`get_context` fan-out; supervision trees give crash-isolation for the pipeline; `Phoenix.PubSub` gives realtime governance for free. Ash's Resource/Action/data-layer model *is* the ports-and-adapters architecture the TypeScript edition built by hand, so the single biggest source of bespoke code disappears. A TypeScript SDK is still mandatory because the agent-harness ecosystem is JS/TS-native — but it is a **generated client** off the OpenAPI contract (§9), not part of the engine language. (Confirms FR §11 with the platform reasoning made explicit; the *behaviour* requirement is unchanged.)
- **AD-LANG-2 — Single Mix release now; no second runtime.** A single Mix release is the distributable in every mode (§13). There is no "faster gateway in another language" escape hatch of the kind the TypeScript edition reserved — the BEAM already gives soft-real-time edge behaviour, and the heavy compute is either in an external model endpoint or in the native NIF tier (Extractous/MDEx parse, Ortex embed, hnswlib ANN), which is Rust/C already. Bun-single-binary and similar are not applicable; the equivalent "small footprint local on-ramp" is the same release image run as one node.
- **AD-TOPO-1 — Mix umbrella (or a single app with clear internal boundaries) + Hex releases for the few publishable artifacts.** Mix + Hex give a content-addressed dependency store and a task graph natively; the publishable artifacts are the **generated consumer SDKs** (TypeScript + Python, from OpenAPI) rather than internal packages. Umbrella apps or `boundary`-enforced contexts hold the module graph; the strict layer-cake enforcement of the TypeScript edition is replaced by Ash's own domain boundaries plus the `boundary` compile-time checker where an explicit wall is wanted.
- **AD-TOPO-2 — Ash-shaped module graph; the conceptual seams are preserved as extension points.** The TypeScript edition's five layers collapse as follows, but the *seams* remain nameable and swappable:

```
SURFACES        Phoenix endpoint: AshJsonApi (/v1) · ash_ai MCP server · gateway proxy · LiveView governance
   ──────────────────────────────────────────────────────────────────── over ▼
DOMAINS + ACTIONS   Ash Domains group Resources; Actions are the typed op layer (the "one op set")
   modules: domain · pipeline(ingest+dream-time via Ash.Reactor) · retrieval/context ·
            governance(gates·queue·audit) · skills
   ──────────────────────────────────────────────────────────────────── depends on ▼
SEAMS (behaviours / extension points)   RetrievalStrategy · EmbeddingModel · gate/auto-accept ·
            chunking · model-tiering        (domain strategies — shipped as code)
   DATA LAYERS + INFRA PORTS   AshPostgres / AshSqlite (storage+vector+lexical) · Oban engine (job-queue) ·
            ReqLLM (model) · secrets · ExAws/FS (blob)      (infrastructure — wired by config)
   ──────────────────────────────────────────────────────────────────── over ▼
PRIMITIVES      Ash resources & types (the lingua franca) · runtime config · telemetry (OTel/:telemetry/Logger)
```

  Dependency rules are now largely *given*: Ash resources define the shared types; **Actions depend on data layers through Ash, never on a concrete Repo directly** (the config/OTP-app boundary is the only binding point — this *is* AINV-1); the **SDKs are generated clients** (depend only on the OpenAPI contract, never on the engine); **enterprise resources/extensions depend on core, core never imports enterprise**, enforced by `boundary` and by keeping `ee` modules in their own OTP app under the licence header.
- **AD-TOPO-3 — Edition boundary = a dedicated `ee` OTP app + runtime licence gate.** Enterprise code lives in a distinct OTP app under a distinct (commercial / Sustainable Use) licence header; the default build can produce a community-only release that excludes it. Modelled on n8n. (See §13 for the gate mechanics.)
- **AD-TOPO-4 — `core` is a modular monolith of Ash Domains** with the five internal modules above kept as separate Domains/contexts — minimising churn, with extraction into separate OTP apps kept mechanical for later.

---

## 4. Component decomposition & internal seams

**Changed from the TypeScript edition:** infrastructure ports become **Ash data layers + a small set of behaviours**; the `withTransaction` unit-of-work is Ash's own transaction wrapping (`Ash.Changeset` + data-layer transactions); domain strategies become **Elixir behaviours**. The categories and cross-port invariants are unchanged.

- **AD-SEAM-1 — Two kinds of seam (AINV-8).** **Infrastructure ports** (driven side: the Ash data layer, the Oban engine, model endpoints, secret stores, blob) are chosen by config at boot. **Domain strategies** are pluggable *policy* behaviours inside `core`/`ee`, shipped as code. "Swap AshSqlite for AshPostgres" and "swap hybrid retrieval for graph retrieval" are different categories.
- **AD-SEAM-2 — Infrastructure ports.**
  - **storage** — transactional persistence of the whole domain (knowledge, scopes, peers, sessions, messages, attributions, provenance, lifecycle, relations, skill cards, audit log, projection cache) as **Ash Resources over AshPostgres / AshSqlite**. Multi-entity operations commit atomically via Ash transactions (`Ash.Changeset` + `Ash.bulk_*` inside a data-layer transaction, or an `Ash.Reactor` transaction step).
  - **vector** — embedding upsert + similarity search. On Postgres: **pgvector via `ash_ai` `vectorize`** (the index write rides the resource's transaction). On SQLite: an **in-memory HNSW index (`hnswlib` NIF)** whose backing **embedding BLOB column is the transactional source of truth**; the HNSW structure is a rebuildable derived cache (FR-PLAT-4).
  - **lexical** — text indexing + keyword/BM25 search (Postgres FTS / SQLite FTS5), expressed via Ash data-layer fragments. Co-located with storage in both backends, so one data layer serves storage + lexical against one connection (and, on Postgres, vector too).
  - **job-queue** — enqueue + delayed/repeatable jobs + retry/backoff + concurrency + rate-limit (the rate-limit doubles as the per-scope budget; FR-FORM-18, FR-PLAT-9). **Oban** (Postgres engine, queue-mode) / **`Oban.Engines.Lite`** (SQLite, single-node), both driven through **AshOban**. **Redis is removed** — Oban is the one queue in both modes.
  - **model** — a provider layer over **ReqLLM** (ash_ai's provider layer; see §8).
  - **secrets** — `get/set/rotate` by reference; env/runtime-config vs Vault/KMS/CMK.
  - **blob** — raw document/object storage (`put/get/delete/signed-url`); local FS vs S3-compatible via **ExAws**.
- **AD-SEAM-3 — Domain strategies.** The **`RetrievalStrategy` behaviour** (semantic + lexical BM25/FTS fused, with optional rerank → the FR-API-25 hybrid default, with room for graph traversal once the structured layer lands; FR §12) wraps hybrid retrieval with a **pgvector adapter and an HNSW adapter** behind one code path (brute-force `Nx` cosine as a tiny-corpus fallback / baseline); plus three more strategy seams: the **gate / auto-accept matrix** (FR-GOV-2), the **chunking/splitting** strategy, and the **model-tiering** policy.
- **AD-SEAM-4 — Cross-port invariants.**
  1. **System of record vs derived cache (AINV-5)** — a reconciler re-enqueues (as an Oban job) any durable record left `pending`/unprocessed, so queue/index/projection loss self-heals; the HNSW index specifically is reconciled from the SQLite embedding blobs at boot and on schedule.
  2. **Unit-of-work + transactional audit** — every state change and its audit entry commit together, in one Ash transaction; partial writes are structurally impossible (FR-GOV-20).
  3. **Transactional outbox** — domain events (session close, doc sync; FR-FORM-17) are realised as an **Oban job inserted in the same DB transaction as the state change** (AshOban), on both engines. This *replaces* the TypeScript edition's separate outbox table + relay: a committed write cannot be lost to a failed enqueue because the enqueue *is* part of the commit. There is no poller/LISTEN-NOTIFY relay to operate.
  4. **Indices update in-transaction by default** — on Postgres, the pgvector + FTS index writes are co-located inside the knowledge-write transaction (atomic, no drift). On SQLite, the embedding blob (the record) is written in-transaction; the HNSW cache is updated in the same process synchronously and is authoritative only as a cache — losing it is a rebuild, never data loss, keeping the "no drift" invariant in spirit. An eventual-consistency external vector DB remains an opt-in path (via an Oban job), not the baseline.

---

## 5. Deployment topology & process model

**Changed from the TypeScript edition:** the four process *roles* (`gateway` / `worker` / `context` / `scheduler`) **collapse to N identical clustered BEAM nodes.** There is no per-role image and no role flag selecting a program subset. Single-node is one supervised BEAM process running everything; queue-mode is the same release on several nodes joined by **libcluster**, with Oban distributing jobs and exactly one Oban cron leader acting as the scheduler singleton. The sync heavy-read fan-out that the TypeScript edition sent by RPC to dedicated context workers becomes **in-VM `Task.async_stream`** (spanning the cluster only when a single node's cores are insufficient).

- **AD-DEPLOY-1 — One image, one program, scaled by node count.** A single Mix release image. Single-node runs one node with everything supervised in-process (surfaces + all Domains + Oban with `Oban.Engines.Lite` + the cron leader). Queue-mode runs the *same* release on N nodes with Oban on the Postgres engine; every node is identical and can serve edge traffic, assemble context, and run pipeline jobs. There is no per-service build and no `MEM_ROLE`-selected subset — a node is either the whole system at small scale or one of many identical peers at large scale.
- **AD-DEPLOY-2 — Two integration paths (AINV-7).** The asynchronous write/pipeline path integrates through the durable substrate: the edge persists raw input and inserts the pipeline Oban job in the same transaction, then returns; any node's Oban workers pick the job up. The synchronous heavy-read path fans out across the BEAM with `Task.async_stream` — across cores on one node, and across the cluster only if needed. In single-node this identical data-flow runs entirely in-process, which is exactly why the two modes are the same system.
- **AD-DEPLOY-3 — The edge is a Phoenix endpoint, not a separate program.** AuthN, Account/tenant scoping, rate-limiting, routing, fan-out orchestration, and response assembly are Phoenix plugs + Ash actor/tenant setup on every node. The OpenAI/Anthropic-compatible proxy (FR-API-21) is one route group *behind* that endpoint, not a distinct process.

```
SINGLE-NODE  (free · one container · one BEAM node)
  one supervised process tree = Phoenix endpoint (MCP · JSON:API · gateway proxy · LiveView gov)
              + all Ash Domains + Oban (Engines.Lite, all queues) + Oban cron leader
  data layer  = AshSqlite  ·  vector = hnswlib in-memory (+ blob-of-record) + FTS5
  blob        = local FS   ·  secrets = runtime config
  → docker compose up   (one image, one volume)

QUEUE-MODE  (enterprise · SAME release · N identical nodes)
  node × N   each: Phoenix edge (authN + tenant scoping + rate-limit + routing) ·
                   in-VM context fan-out (Task.async_stream) · Oban workers (ingest + dream) ·
                   gateway proxy · LiveView governance
  one Oban cron leader (scheduler singleton; elected via Oban/`:global`)
  clustering via libcluster
  ─────────────────────────────────────────────────────────────────────────────
  integrate ONLY through the durable substrate:
    Postgres(pgvector + FTS + Oban) · S3-blob · KMS      → no service-to-service RPC on the write path
    (Redis is gone; Oban is the queue; PubSub rides Phoenix.PubSub over distribution)
```

- **AD-DEPLOY-4 — Nodes scale horizontally; the cron leader is the one singleton.** Every node is stateless (all durable state in Postgres/S3; ephemeral caches in ETS) and scales by adding nodes. The **Oban cron leader** is the singleton analogue of the old `scheduler` — its outage delays *scheduled* dream-time work only (no data loss; jobs are idempotent, and leadership re-elects). HA leader-election beyond Oban's built-in mechanism is the upgrade if a timeliness SLO ever demands it (§18).
- **AD-DEPLOY-5 — What flips between modes** (everything else is byte-identical, driven by runtime config): data layer `AshSqlite ↔ AshPostgres`; vector/lexical `hnswlib+FTS5 ↔ pgvector+PG-FTS`; Oban engine `Engines.Lite ↔ Postgres`; blob `local-FS ↔ S3`; secrets `runtime-config ↔ Vault/KMS`; clustering `off ↔ libcluster`; multitenancy strategy `single-account ↔ :context(+RLS)/schema/db`. The transactional outbox needs *no* flip — it is an Oban insert in-transaction in both engines.
- **AD-DEPLOY-6 — Internal traffic is authenticated in multi-node.** BEAM distribution between nodes uses TLS-distribution with a shared release cookie / cert, so the cluster network is not a trust boundary; any HTTP the deployment still exposes internally uses mTLS / signed tokens as before.

---

## 6. Data & storage architecture

**Changed from the TypeScript edition:** the relational + migration layer is **AshPostgres / AshSqlite with Ash-generated migrations** (replacing Drizzle); the temporal ledger, materialized current-state, confidence-at-read, materialized-path scope tree, co-located indices, isolation tiers, CMK, and append-only hash-chained audit are all expressed as **Ash Resources, calculations, changes, and policies**. The *data model and invariants are unchanged.*

- **AD-DATA-1 — Temporal / lifecycle model: immutable content + an append-only state-transition ledger.** Per FR-FORM-20, a content change is a *new item that supersedes the old* — content is never edited in place — so a knowledge item's statement is effectively immutable; what changes over its life is state, attribution/level, and confidence. Therefore: immutable content + stable id, plus an append-only transition ledger per item. In Ash this is enforced structurally by **not defining `update`/`destroy` actions on the content and ledger resources**: a `Knowledge` row is create-only, and a content change creates a new `Knowledge` with a `supersedes` relationship. The ledger (`LedgerEvent`) *is* the belief-time source (FR-KN-17). Valid-time is the `expires` field; salience is `relevant-window`. This is the classical bi-temporal split — transaction-time (here: belief-time) vs valid-time [12] — the same model the temporal-knowledge-graph memory line converged on for agent memory (Graphiti's `t_created`/`t_invalid` vs `t_valid`/`t_invalid` edge dating [1]); ours adds the independent salience axis on top. `as_of(D)` (FR-API-23) is an **Ash calculation/preparation** producing an indexable interval filter — "items whose active interval covered belief-time D" — no log fold; optionally AND'd with "not expired as of D". The history/diff view (FR-GOV-21) is the ledger + audit entries; supersession chains are walked via the `supersedes` relation.

```
K1  proposed@t0 → active@t1 → superseded@t3   (expires = t5)
K2                proposed@t2 → active@t3      (supersedes K1)
   belief-time active intervals:  K1 = [t1,t3)   K2 = [t3,…)
   as_of(t2) → K1     as_of(t4) → K2
```

- **AD-DATA-2 — Confidence is computed, not journaled.** Store base confidence + last-revalidated timestamp + decay policy; compute effective confidence at read time as an **Ash calculation** (FR-GOV-10). The decay function is a strategy behaviour (default: exponential, Ebbinghaus-style forgetting curve [8]). Only material events — confirm, correct, gate decision, supersede — append to the ledger.
- **AD-DATA-3 — Materialize current state.** Lifecycle state, base confidence, and current attribution are materialised as attributes on the knowledge row, kept in sync with the ledger inside the same Ash transaction (via an `after_action` change or a `Reactor` step). The hot read path (`get_context` / `ask`) is then a cheap indexed read with no fold; the ledger remains the source of truth.
- **AD-DATA-4 — Scope tree = materialized path; graph = edge table.** Containment is a portable path-string attribute + prefix index (identical in Postgres and SQLite), giving the ordered ancestor chain directly for "merge along the containment path, nearest-wins" (FR-API-2) and subtree visibility (FR-TOP-10); ancestor merge is a `like 'path/%'` Ash filter. The cross-cutting relationship graph is a `ScopeRelation` resource (`from_scope, to_scope, relation_type, metadata`), traversed permission-filtered (FR-API-3). `ltree` is deliberately avoided — it would be a Postgres-only fast path that breaks two-backend parity. (Unchanged from the TypeScript edition's AD-DATA-4.)
- **AD-DATA-5 — Vector + lexical co-located; two embedding collections.** Both indices live with storage so index writes ride the knowledge-write transaction (AD-SEAM-4.4): on Postgres via `ash_ai` `vectorize` + pgvector + PG-FTS in one connection; on SQLite via the embedding BLOB column (of record) + the in-memory HNSW cache + FTS5. Two logical collections: knowledge-statement embeddings (for retrieving knowledge) and document-chunk embeddings (for `search`, FR-API-7). Both feed the FR-API-25 hybrid fusion through the single `RetrievalStrategy`.
- **AD-DATA-6 — Isolation.** Single-node is single-Account (isolation moot). Queue/SaaS default: **Ash `:context` multitenancy** (a tenant filter applied to every query) **plus Postgres RLS keyed on Account** as DB-enforced defense-in-depth (FR-PLAT-6) — Ash gives the app-level filter, RLS is a deliberate add-on, not automatic. Enterprise high-isolation makes tenancy a data-layer strategy: `:context`+RLS → **schema-per-account** (AshPostgres `manage_tenant` templating) → **db-per-account** (a separate Ash `Repo` per Account) (FR-PLAT-7).
- **AD-DATA-7 — CMK = storage/volume-level encryption with a customer-supplied KMS key** (DB volume + blob bucket), because that is what "supply and rotate your own keys for data at rest" (FR-PLAT-15) means and it avoids the trap that you cannot FTS or vector-search ciphertext. Field-level app-encryption of specific `restricted` fields is an optional additional layer via an Ash custom type / `change` (e.g. `cloak`-style), with that searchability caveat noted (and made explicit in FR-PLAT-15).
- **AD-DATA-8 — Audit log: append-only, reference-by-id/hash, per-Account hash-chain.** No `update`/`destroy` actions on the `AuditEntry` resource (immutability as contract); written in the same transaction as the change (AD-SEAM-4.2) via an Ash `change`; references content by **id + content-hash, not value** (FR-GOV-17), so erasure leaves the *event* intact while the content goes; a **per-Account hash-chain** (each entry carries the prior entry's hash, computed in the write `change`) gives cryptographic tamper-evidence without serialising appends across tenants.
- **AD-DATA-9 — Migrations: Ash-generated, shared-core + per-backend divergence, expand/contract.** Ash generates migrations from resource definitions for *both* AshPostgres and AshSqlite (`mix ash.codegen`), keeping the SQL-first control needed for pgvector/RLS/FTS via data-layer options and custom migration statements where the generator stops. The core relational schema is shared; vector/FTS/RLS pieces have per-backend migration fragments. Rolling deploys require **expand/contract** migrations so old and new code run simultaneously mid-deploy.

**Changed from the TypeScript edition:** Drizzle → Ash-generated migrations; index co-location on SQLite splits into "blob-of-record in the transaction" + "HNSW cache reconciled from blobs"; isolation gains the explicit Ash `:context` + RLS layering. The temporal/ledger/confidence/scope-tree/audit semantics are identical.

---

## 7. Asynchronous pipeline & job orchestration

**Changed from the TypeScript edition:** the two-runner split (in-process runner *or* BullMQ/Redis) collapses to **one job system in both modes — Oban via AshOban** (`Oban.Engines.Lite` on SQLite single-node, the Postgres engine in queue-mode). **Redis is removed.** Pipeline orchestration (saga steps, compensation, deterministic idempotency keys) is **Ash.Reactor**, triggered by AshOban. The transactional outbox is an Oban insert in the write transaction (AD-SEAM-4.3). The human-in-the-loop "wait for approval" continuation is a held state + a decision-triggered Oban job, not a bespoke durable-execution layer.

- **AD-PIPE-1 — Oban (via AshOban) for jobs; Ash.Reactor for orchestration.** The queue engine is `Oban.Engines.Lite` (single-node) / Oban-Postgres (queue-mode) — the *same job code both modes*, a strict improvement on the TypeScript edition's two different runners. Each pipeline lane is an **Ash.Reactor** flow: discrete steps with compensation (saga rollback) and a durable-continuation / signal-on-approval seam for the human gate. A heavyweight external durable-execution engine (Temporal/DBOS) is explicitly **not** adopted — Reactor + Oban already give step orchestration, retries, idempotency, and human-in-the-loop parking, and the long-running-approval case is pre-solved by the durable knowledge-lifecycle state machine.

```
INGEST-TIME  (fast lane · cheap model · event-triggered · high-priority Oban queue)
  raw msg/doc persisted by edge → Oban job inserted in SAME tx (outbox)
    → extract: propose knowledge (subject≠source, hearsay-discounted; temporal + sensitivity proposed)
               + resolve update-op per candidate: add / merge / supersede-candidate / no-op (FR-FORM-14)
               + update session summary
    → cheap exact/near-dup check (embedding lookup)
    → gate-matrix check (NO LLM): peer-level → provisional-accept ; scope-level → hold ;
                                   below bar / sensitive → route to queue
    → write proposed/active + ledger + indices   (one Ash transaction)

DREAM-TIME  (slow lane · strong model · per scope · Oban cron + events · low-priority, budget-capped)
  over (scope, since-watermark) delta + working set:
    → higher-order deductions (reflection)
    → deep contradiction / supersession → non-obvious conflict = validation item
         (prior knowledge bundled) → curator/peer   [3rd gate]
    → corroboration leveling (Gate B) · pattern surfacing · memory evolution (relation upkeep)
    → refresh projections (incremental, AD-PIPE-7) · revalidation / expiry

SWEEPS & SYNC  (Oban cron)
  revalidation/expiry · pending-item aging (escalate / auto-reject)
  connector sync (content-hash) → changed docs → re-extract + supersede
```

- **AD-PIPE-2 — Ingest-time = extraction + cheap gating only.** No LLM reasoning, no leveling, no deep conflict at ingest-time (FR-FORM-14). A cheap, no-LLM gate-matrix check runs so **peer-level knowledge is usable provisionally and immediately** (FR-GOV-6) — load-bearing for the personal and SaaS shapes. Everything needing the working set or a strong model runs at dream-time (FR-FORM-16). The two-lane split is grounded twice over: the fast extract-then-update phase is the production pattern validated by Mem0 [2]; spending strong-model tokens offline so the hot path needs none is the sleep-time-compute result [4] — it cut test-time compute ~5× for equal accuracy precisely because idle-period reasoning over persistent context is amortised across future queries.
- **AD-PIPE-3 — Priority & backpressure.** Separate named Oban queues per job-type, each with its own concurrency and rate-limit. Ingest-time runs high-priority/low-latency and effectively uncapped; dream-time runs low-priority and **budget-capped, and is shed first under pressure** (FR-PLAT-9). Raw ingest never blocks on extraction (persist-then-enqueue-in-tx + reconciler), so under load the system loses *freshness*, never data. Provider rate-limits feed the same backpressure. Oban's per-queue rate-limiting is the mechanism, and it doubles as the per-scope budget lever.
- **AD-PIPE-4 — Per-scope budgets at admission; model tiering; idempotency.** Before dispatching an expensive dream-time pass, check the scope's remaining token budget (from the §12 meter); if exhausted, defer (Oban `snooze`). Jobs map job-type → model-role (cheap extractor / strong reasoner / dialectic). Every job is keyed with an **Oban unique key** derived deterministically (`extract` by message-id+content-hash, `dream` by scope+watermark), so re-runs are safe via dedup/merge (FR-KN-9) and the reconciler's re-enqueue is harmless.
- **AD-PIPE-5 — Event-triggered dream-time is debounced with a nightly floor.** Session-close marks the scope dirty and schedules a coalesced Oban job after a quiet period (unique-key debounce), with a guaranteed nightly cron run — balancing freshness against budget, since provisional peer-level knowledge is already live from the fast lane.
- **AD-PIPE-6 — Human-signal continuation seam.** The third-gate "wait for curator approval" is a continuation point: the Reactor flow writes the validation item + hold state and completes; the curator's decision event (supersede / keep-both / reject / merge; FR-FORM-22) enqueues the continuation Oban job that resumes the downstream steps. Same domain step-sequence as the TypeScript edition, now expressed as a Reactor flow parked on a decision rather than a BullMQ callback — no separate durable-execution substrate needed.
- **AD-PIPE-7 — Projection refresh is incremental, never a monolithic rewrite (FR-KN-16).** The dream-time projection step computes the delta of changed knowledge since the projection's watermark and applies **structured delta updates** (add/replace/remove sections keyed to knowledge ids), with periodic full compaction allowed only when diffed and bounded. Rationale: iterative wholesale LLM rewriting of an evolving artifact measurably erodes accumulated detail — "context collapse" [9] — and costs strictly more tokens than a delta; keying projection fragments to knowledge ids also makes the FR-GOV-21 diff view and FR-GOV-15 recomputation surgical instead of total. (Semantics unchanged.)

---

## 8. Model & provider abstraction

**Changed from the TypeScript edition:** the provider factory over the Vercel AI SDK becomes a provider layer over **ReqLLM** (ash_ai's provider layer); the capability interfaces become **Elixir behaviours**; the embedder is a pluggable **`AshAi.EmbeddingModel` behaviour** whose default self-hosted implementation is **Ortex (ONNX Runtime, Rust-backed; bge-small / all-MiniLM class)**, with **Bumblebee + EXLA** for GPU and a BYO-key API embedder also supported. Structured output uses Ash actions + validate-and-repair against Ash resource schemas rather than Zod. The four model roles and every semantic guarantee (grounding, abstention, pinned embedder, provenance, single metering point) are unchanged.

- **AD-MODEL-1 — A provider layer over ReqLLM + capability behaviours.** Configured by a role → (provider, model, params) map at **Account level** (FR-API-18; per-scope overrides deferred, FR §12). Capability behaviours: `Embedder` (the `AshAi.EmbeddingModel` behaviour), `StructuredGenerator` (extractor and reasoner share it, differing by configured tier), `ChatGenerator` (streaming; dialectic + gateway), optional `Reranker` (model-based cross-encoder *or* score-fusion; the FR-API-25 rerank stage). ReqLLM supports OpenAI-compatible and self-hosted endpoints (Ollama, vLLM; FR-API-19). BYO-key throughout. The four roles are unchanged: embedder, ingest extractor (cheap), dream reasoner (strong), dialectic agent.
- **AD-MODEL-2 — Structured output via Ash resource schemas + validate-and-repair.** The extractor/reasoner emit records against the *same* Ash resource schemas as the DB shape (no separate Zod layer — the resource *is* the schema). Generation via a structured-output action with a bounded **validate-and-repair retry** as the portable baseline (essential for weak self-hosted models), plus optional **constrained decoding** where a provider supports it (e.g. vLLM guided decoding). Extraction/reasoning are non-streaming. ash_ai's prompt-backed actions provide the structured-generation plumbing.
- **AD-MODEL-3 — Streaming only for dialectic + gateway; `ask` is a bounded, grounded, read-only tool-calling loop.** `ChatGenerator` streams; the gateway proxy tees the upstream stream (to the client + accumulate for capture). `ask` is a prompt-backed action given the *read* APIs as tools (resolve-scope, `query_knowledge`, `search`) for decomposition and multi-hop (FR-API-6) and can never write (FR-API-12); its sub-queries are what the edge fans out with `Task.async_stream` (AD-DEPLOY-2). **Grounding & abstention (FR-API-26) are enforced structurally, not by prompt alone:** the dialectic loop must return the knowledge ids it used (the response schema requires citations), and the assembler verifies every cited id was actually retrieved in-loop; absent / `expired` / `needs_revalidation` knowledge is surfaced to the model as explicitly *unknown-or-stale*, and an "insufficient memory" answer is a first-class, schema-valid outcome — abstention is where memory systems measurably fail [10, 11], so it is designed in, not hoped for. (`bitcrowd/rag`'s built-in groundedness / context-relevance / answer-relevance eval is a bonus signal for this NFR; see §15.)
- **AD-MODEL-4 — Single provider for v1; fallback is a deployment concern; the embedder is pinned.** Retry+backoff on transient errors; provider rate-limits feed backpressure. Multi-provider fallback is achieved by pointing a role at an OpenAI-compatible proxy (e.g. LiteLLM) — not built into the engine. The **embedder is pinned and never silently falls back to a different model** (incompatible vector spaces would corrupt the index); changing it is a **versioned re-embed migration**, and every embedding is tagged with its model + version. This intent is unchanged; the mechanism is the `AshAi.EmbeddingModel` behaviour (Ortex default), pinned per embedding at write time.
- **AD-MODEL-5 — Provenance records model + version + prompt/pipeline version** (extends FR-KN-5), so extraction is auditable and the eval harness (§15) can pin versions for regression.
- **AD-MODEL-6 — Secrets by ref; one metering emission point.** Configs hold secret refs only; raw keys live solely in the secrets backend, redacted from logs/audit/metering. The ReqLLM provider layer is the single emission point for a usage record per call — `{account, scope, role, provider, model, tokens in/out/embed, latency, ts}` — feeding budgets, SaaS billing, and self-host cost visibility (FR-PLAT-8). The consumer's agent model is out of scope (FR-API-20).

---

## 9. API surfaces & contracts

**Changed from the TypeScript edition:** the "one op definition, many transports" principle is realised natively — the five reads + `ingest` are **Ash Actions**, exposed as **AshJsonApi** (`/v1` JSON:API + auto-generated OpenAPI, the canonical machine transport), the **`ash_ai` MCP server** (reads + `ingest` as tools; governance NOT on MCP), the **Phoenix gateway proxy** (OpenAI/Anthropic-compatible), and the **LiveView governance app** (§10). Consumer SDKs (TypeScript + Python) are generated from the OpenAPI document. AshGraphql is omitted in v1.

- **AD-API-1 — One operation definition, many transports.** The five reads + `ingest` are defined once as **Ash Actions** on the domain resources; every surface is a thin adapter Ash already provides over those actions.

```
CLIENTS   agent-host(MCP) · generated SDK (TS/Py) · OpenAI-compat harness · curator(browser/LiveView)
                               │
                     ┌─────────▼──────────┐
                     │  PHOENIX ENDPOINT   │  authN · tenant scoping · rate-limit · routing · fan-out
                     └─┬─────┬───────┬───┬─┘
        reads+ingest    │     │       │   │   governance (human SSO + RBAC, NOT on MCP)
        for agents →  MCP  JSON:API gw-proxy  LiveView GOV
                        └─────┴───┬───┴────────┘
                                  ▼
                        ASH ACTIONS  (one typed op set on the resources)
                                  ▼
                              core Domains
```

- **AD-API-2 — Four surfaces.** The **HTTP API** (AshJsonApi, versioned `/v1`, language-neutral JSON:API) is the canonical machine transport, used by the generated SDKs, governance flows, and the gateway. **MCP** (the `ash_ai` MCP server) is a parallel surface for agent hosts: the same reads + ingest actions annotated as MCP tools (FR-API-11). The **gateway-proxy** internally calls inject (read) + capture (ingest). The **governance** surface is separate (FR-API-13) and is the LiveView app (§10).
- **AD-API-3 — OpenAPI is the canonical contract, generated by AshJsonApi.** Versioned in-path (`/v1/…`); the generated SDKs and the resource schemas carry semver; MCP tool schemas are versioned too (they are part of what the agent's model sees). Evolution is additive / expand-contract.
- **AD-API-4 — Auth as a structural boundary.** FR-API-12/13 is realised as **separate surfaces with separate auth**, not just separate endpoints: agents and the SDK authenticate with machine credentials and reach only MCP + the read/ingest JSON:API actions; an agent credential *cannot* reach a governance action because governance isn't on the agent-facing surface at all (and Ash policies deny it in depth). The governance surface uses human SSO + curator RBAC.
- **AD-API-5 — Harness SDK shape** (FR-API-14–16): the generated TS/Python clients provide thin primitives (session/peer/scope helpers, the reads, ingest) + an optional agent-loop helper; a context-injection helper that formats `get_context` into any provider's message shape; auto-forwarding of each turn to ingest; a skill-readiness wrapper that runs `check_readiness` and drives elicitation. Client-only dependency, usable over HTTP/MCP, provider-agnostic. (The engine is Elixir; the SDKs are generated artifacts, so the harness ecosystem's JS/TS requirement is met without the engine being TS.)
- **AD-API-6 — Gateway-proxy modes + session identity.** Three integration modes (MCP tools / proxy / native hooks); session id taken from the harness thread id or gateway request stream, else inferred by peer + scope + idle-gap (FR-API-21/22).

---

## 10. Headless governance & interaction channels

**Changed from the TypeScript edition:** the separate `app:web` governance SPA becomes a **Phoenix LiveView** app over the same Ash resources, with realtime via **`Ash.Notifier.PubSub` + Phoenix.PubSub** — deleting the SPA and its API round-trips. The channel-adapter model (Slack/Teams/Telegram/email) and every governance/audit semantic are unchanged; the web UI is simply one more channel adapter, now server-rendered.

- **AD-GOV-1 — Governance is delivered through channel adapters over the governance op layer; the LiveView app is one adapter.** Outbound *notify* (a validation item needs a curator, or a peer needs revalidation/consent → push an actionable message) and inbound *act* (the response translates back into a governance Ash action: approve / reject / merge / defer / confirm-scope / consent; FR-GOV-5/8/12). LiveView subscribes to `Ash.Notifier.PubSub` so the validation queue, curator dashboards, knowledge history/diff view, and peer self-view update in realtime with no polling. This directly mitigates the blueprint's governance-latency risk by pushing approvals to where curators already are, and extends FR-GOV-10's inline revalidation to reach people *between* sessions.
- **AD-GOV-2 — Channel assurance is a hierarchy, and authZ runs against the mapped peer regardless.** Slack/Teams have request-signing and verified identities (high assurance — a signed action is trusted as that user); Telegram is usable only after explicit one-time linking (medium); **email is notify + magic-link only — a reply is never authorization** (the action happens behind a one-time, expiring, single-purpose authenticated link). Each inbound channel webhook is a Phoenix endpoint that must verify the channel signature and resolve tenant as rigorously as the edge (a plug enforcing AINV-6 before any Ash action runs).
- **AD-GOV-3 — Sensitivity-gated routing + per-Account channel allowlist.** Low-sensitivity items may include content inline; high-sensitivity items go *notify-only* (content stays inside the boundary). An Account sets which channels are permitted at all (e.g. a regulated org allows only Slack within its tenant and forces the LiveView UI for `restricted`). This implements the FR-PLAT-16 compliance posture.
- **AD-GOV-4 — Audit is enriched, not weakened.** Every action through any channel flows through the governance Ash action → gate decision → hash-chained audit (AD-DATA-8), with the actor being the *mapped peer* and the channel recorded as provenance.
- **AD-GOV-5 — Phasing.** Build the interaction-channel port now (the LiveView UI is itself an adapter); ship LiveView UI + Slack + email-notify early; Teams and Telegram as later adapters. A basic validation/curator UI ships in the free core; heavier compliance surfaces (audit-export views, org-wide dashboards, advanced RBAC management) are enterprise.

---

## 11. Security, identity & tenancy

**Changed from the TypeScript edition:** the in-house AuthZ resolver becomes **Ash.Policy.Authorizer + field policies**; multitenancy becomes **Ash multitenancy** (`:context` + Postgres RLS → `manage_tenant` schema → per-Account Repo); free-tier auth becomes **AshAuthentication** (password / API-key / magic-link); enterprise SSO becomes **ExSaml or Samly** (SAML SP) + **assent** (OIDC); SCIM is **implemented over Ash**. The hard wall, identity model, RBAC semantics (deny-wins, per-grant propagation), and deprovisioning≠erasure are all unchanged.

- **AD-SEC-1 — The hard wall (AINV-6).** Account is derived from the authenticated identity, never from a request parameter, and is re-checked in depth: identity-bound account set as the Ash `tenant`/`actor` at the Phoenix edge, authZ re-checked by Ash policies at the action layer, RLS or schema/db-per-account at storage, per-Account namespaces for blobs and secrets. Cross-account access is structurally impossible (FR-TOP-1, INV-8).

```
REQUEST AUTHZ  (every request, every surface)

  external identity                 resolves to
    SSO subject (SAML/OIDC)  ┐
    API key / token          ├──►  PEER  (account-scoped)
    signed Slack/Teams action│         │
    linked Telegram id       │         ├─► role grants on the scope tree
    SSO-verified email       ┘         │     (per-grant propagate flag, Linux/ACL-style)
                                       │             │
            identity's assurance ◄─────┘             ▼
                    │                        read S iff an applicable grant on S
                    ▼                        or a propagating ancestor (FR-GOV-19)
        sensitivity × assurance
        (restricted ⇒ high-assurance only)
                    │
                    ▼
  ── HARD WALL (account never crossed · defense in depth) ──
   edge    : account derived from IDENTITY → Ash tenant/actor, never from request params
   actions : Ash.Policy.Authorizer re-checks; any caller-supplied account_id ignored
   storage : Ash :context + Postgres RLS / schema-per-account   blob+secrets: per-account namespaces
```

- **AD-SEC-2 — Identity model.** The **peer** is the domain identity (human or agent, symmetric), an Ash resource. External identities are *linked to a peer*, account-scoped, in a `peer ↔ external_identity` resource (`{kind: idp|apikey|slack|teams|telegram|email, external_id, assurance, linked_at}`). A verified email claim comes free from SSO; Slack/Teams/Telegram require a one-time **account-linking flow** (authenticate the trusted way, then bind the channel id). Each link carries an **assurance level** consumed by the sensitivity×assurance check (AD-GOV-2).
- **AD-SEC-3 — RBAC: per-grant propagation flag (Linux/Windows-ACL semantics), via Ash policies.** Roles — account-admin, curator, member, reader (FR-GOV-18) — are granted per-scope. Each grant carries a `propagate` flag (this-scope-only vs this-scope-and-subtree). Resolution at scope S: gather S + propagating ancestors via the materialized path, take the applicable allows. **Deny entries** (Windows-ACL style, deny-wins) are the mechanism for carving a peer out of a sensitive subtree (decision pending, §18 — lean: include). This is expressed as **Ash policies** (read/action authorization) plus **field policies** for sensitivity-scoped attributes; RLS enforces the **account** wall at the DB, these policies enforce **scope-level** read access at the action layer — defense in depth, not duplication. A Zanzibar-style relationship-tuple engine [13] (OpenFGA / SpiceDB) remains droppable behind the policy layer as an enterprise ReBAC adapter.

```
role_grant = { peer_id, scope_id, role, effect: allow|deny, propagate: bool, granted_by, granted_at }
effective at S = max(applicable allows where scope=S OR (ancestor AND propagate)) MINUS matching deny
read S iff effective is non-empty      (evaluated in an Ash policy check)
```

- **AD-SEC-4 — Build auth on Ash-native + standards libs; do NOT depend on Clerk/WorkOS.** Both are hosted SaaS and would break "runs out of the box locally," "own your data," and self-host↔SaaS portability — and are a dealbreaker for the regulated buyer. Instead: free core uses **AshAuthentication** (password / API-key / magic-link, local, owns its tables); enterprise adds standards-based **SAML SP via ExSaml or Samly** (SP- and IdP-initiated SSO, Single Logout, SP metadata, multi-IdP; both are mature and Azure-AD-proven — pick one in the spike) + **OIDC via assent** + a **SCIM 2.0 endpoint implemented over Ash** (Users/Groups CRUD + filter, with group → scope-role mapping; the `scim` hex Plug scaffold is a starting point, OIDC-JIT provisioning is the early-customer fallback). The same self-hostable stack runs in every mode, including the managed SaaS — no hosted-auth dependency anywhere.
- **AD-SEC-5 — Agents are peers (member/reader); curator is a human role.** Granting curator to an agent is a no-op for governance actions (the governance surface is human-only, enforced by Ash policy). API keys are per-Account, bound to a peer, optionally scope-restricted for least privilege (AshAuthentication API-key strategy).
- **AD-SEC-6 — Deprovisioning ≠ erasure.** SCIM offboarding revokes access and unlinks identities; knowledge the peer sourced or that is about them persists until the separate, governed right-to-be-forgotten flow runs it (FR-GOV-15/16). Losing access never silently deletes data.

---

## 12. Observability & metering

**Changed from the TypeScript edition:** OpenTelemetry JS + pino become **OpenTelemetry Elixir + `:telemetry` + Logger**; queue-context propagation rides Oban job args + OTel context; metering stays a durable exact ledger in the DB (now an Ash `UsageEvent` resource). The three-pipeline separation and every metering/telemetry semantic are unchanged.

- **AD-OBS-1 — Three telemetry pipelines, never conflated.** **Operational observability** (operator-facing, lossy-tolerant, their backend), **metering** (money/budgets, exact, in their DB), and **product telemetry** (vendor-facing, anonymous).
- **AD-OBS-2 — Observability via OpenTelemetry, vendor-neutral, off-by-default on single-node.** OpenTelemetry Elixir + the `:telemetry` ecosystem (Phoenix, Ecto, Oban, Ash all emit `:telemetry` events) for traces and metrics; structured JSON via `Logger` correlated to trace ids. Emit OTLP; the operator points it at their own backend (Grafana/Tempo/Loki, Datadog, Honeycomb…). The key engineering bit: **trace context (W3C `traceparent`) is propagated through the queue** (injected into the Oban job args, continued by the worker), giving end-to-end traces from "message in" → "knowledge minted" → "projection refreshed." Metrics include the FR-PLAT-10 ops set (queue depth via Oban, latency, error rates) plus RED/USE. On single-node it is zero-config off; opt-in to enable.
- **AD-OBS-3 — Sensitivity-aware log redaction.** Secrets/keys never logged; knowledge content is **never logged above debug level**, and at debug only behind an explicit config flag and **never for `restricted`** (FR-GOV-11). Ash field policies keep `restricted` fields out of default logging paths.
- **AD-OBS-4 — Metering is a durable, exact ledger, not OTel.** An append-only `UsageEvent` Ash resource in the DB — exact, attributed to `{account, scope, role}`, sourced from the ReqLLM provider layer's single emission point (AD-MODEL-6) plus periodic storage-size measurement and edge-side ingest/API counts. It rolls up into materialised per-scope counters (kept warm in ETS for fast budget admission, AD-PIPE-4) and feeds SaaS billing and the self-host cost dashboard (FR-PLAT-8). Sampled-and-lossy for OTel; exact-and-durable for money.
- **AD-OBS-5 — Product telemetry is anonymous opt-out on self-host, identified on SaaS, opt-in for contacts.** A mandatory phone-home is rejected — it contradicts the data-ownership thesis, is impossible air-gapped, risks GDPR, and is unnecessary (opt-out captures the overwhelming majority of installs). So: self-host free = anonymous, on-by-default, **opt-out** (random instance id, version, deploy mode, feature-usage; never content, never contacts; first-run notice + `MEM_TELEMETRY_ENABLED=false`), built on PostHog (self-hostable); self-host enterprise = off / air-gapped (the licence is the relationship); managed SaaS = fully identified usage, ToS-governed (legitimate, not phone-home); **contacts only via an opt-in free-licence registration** that unlocks some otherwise-enterprise features (specific set TBD, §18; gate additive niceties, never core, transparently).
- **AD-OBS-6 — Optional local observability stack.** Emit-only by default, plus an optional `--profile observability` compose stack (OTel Collector + Grafana/Tempo/Loki/Prometheus, or Jaeger) — never required, one command away.
- **AD-OBS-7 — Health/readiness endpoints** (liveness + DB/queue reachability, via a Phoenix health route + Oban/Repo checks) feed the compose/k8s healthchecks. Edition: OTLP emission, ops metrics, health, and basic cost-visibility are free core; advanced retention, prebuilt dashboards, and audit/usage export to a SIEM are enterprise (FR-PLAT-13, FR-PLAT-13a).

---

## 13. Configuration, packaging, distribution & licensing

**Changed from the TypeScript edition:** infra/deploy config is **Elixir runtime config** (`config/runtime.exs`), validated at boot (replacing dotenv/Zod); packaging is a **single Mix release image** with the role selected by runtime config (no `MEM_ROLE` program subset — a node is the whole system, scaled by count); the ed25519-signed licence token is verified **in Elixir** against an embedded public key. Policy/behaviour config stays DB-stored and tree-inherited. The two-kinds-of-config split, the licence-gate model, and the fair-code stance are unchanged.

- **AD-CFG-1 — Configuration is two kinds; only one is layered.**

```
INFRA / DEPLOY  (config/runtime.exs · validated at boot · fail-fast · per node)
  data-layer selection · connection strings · clustering topology · OTLP endpoint ·
  LICENSE KEY · ports        secrets are NOT here — referenced by ref, resolved via the secrets port

POLICY / BEHAVIOUR  (DB-stored Ash resources · runtime-editable · no redeploy)
  account level   model roles (FR-API-18) · channel allowlist · auto-accept matrix ·
                  budgets · retention · sensitivity defaults
       ▼ scope overrides account, INHERITS DOWN the tree (nearest-wins)
  scope level     scope policy · per-scope budget · skill-card overrides
  → effective config = scope (nearest-wins) over account
```

  Infra/deploy config is `config/runtime.exs`, validated at boot, fail-fast. Policy/behavioural config lives in the DB as Ash resources, runtime-editable via the admin/governance LiveView surface, with the scope layer inheriting down the tree (nearest-wins) — the same grain as knowledge visibility and RBAC (FR §10, invariant 7). Secrets appear in neither.
- **AD-CFG-2 — Packaging & distribution.** One Mix release Docker image, published to GHCR. Two compose files: single-node (free — app + volume, `docker compose up`, AshSqlite + Oban.Engines.Lite) and queue-mode (licensed — Postgres + MinIO + N clustered nodes; **no Redis**), with compose **profiles** for optional pieces. The zero-friction local on-ramp is the same release run as one node (the BEAM already gives a single self-contained process; no separate `npx`-style runner is needed). Migrations auto-run on boot for single-node (`Ash`/Ecto migrate on start); an explicit migrate step before rollout in production. Helm for k8s/cloud scale (with libcluster topology) comes later.
- **AD-CFG-3 — Licence gate: signed, offline-verifiable token + entitlement service.** An ed25519-signed, JWT-shaped licence token carries entitlements (features, limits, expiry); the app verifies it **offline in Elixir** against an embedded public key (essential for air-gapped buyers), with periodic online renewal and an offline grace window. A central `enabled?(feature)` entitlement module gates the `ee` OTP app's code paths at boot/config (queue-mode entitlement; 2nd Account → multi-account; SAML → SSO; etc.). Missing/expired licence turns enterprise features **off with a clear message** — never a crash, never data loss. Modelled on n8n's licence-SDK pattern.
- **AD-CFG-4 — The gate is honesty + legal terms, not unbreakable DRM.** The `ee` source is visible (source-available under the Sustainable Use Licence); a determined actor could patch the check, but doing so violates the licence, and the model relies on enterprises buying for legitimacy, support, and compliance. Over-hardening would be futile (source-available) and against the fair-code spirit.
- **AD-CFG-5 — One image (use-gated), plus a free-licence middle band.** A single release image with the `ee` OTP app present-but-gated (a community-only build that excludes it is kept available if a provably-clean artifact is ever demanded). A free-licence registration unlocks some otherwise-enterprise features (specific set TBD, §18), gating additive niceties, never core capability.

---

## 14. Portability & migration

**Changed from the TypeScript edition:** export/import now moves data between the **AshSqlite** and **AshPostgres** data layers; derived indices not exported specifically include the **HNSW index** (rebuilt on import from the embedding blobs). The logical-not-physical export format, both-directions requirement, offline-snapshot-for-v1, and DR posture are unchanged.

- **AD-PORT-1 — Export is logical, not physical.** The format is a versioned, self-describing archive of the *domain model* (manifest with schema version + embedder model/version + counts + sha256 checksums, then JSONL per Ash resource type, plus blobs) — **not** a `pg_dump` or a SQLite file copy — because only a logical, backend-agnostic format makes self-host(AshSqlite) ↔ SaaS(AshPostgres) migration work (AD-DATA-* keeps the schema portable). The format is versioned (expand/contract).

```
ACCOUNT EXPORT — what travels, and how
  domain data       knowledge (+ledger, provenance, attributions, relations, lifecycle), scopes
  (portable, §6)    (tree+graph), peers, sessions, messages, skill cards, config, queue state,
                    identity links  → JSONL per resource, streamed
  audit log         exported WITH its per-account hash-chain intact; import verifies, then continues
  blobs             raw bytes (bundled for small accounts, streamed separately for large)
  derived indices   pgvector / HNSW / FTS — NOT exported; REBUILT on import (re-embed job)
  secrets / keys    NEVER exported — refs only; operator re-provisions at target
                    (CMK: decrypt at source → transport-encrypted → re-encrypt under target key)
  usage/metering    optional (cost-history continuity)
```

- **AD-PORT-2 — Migration runs both directions; the reverse one is the point.** Self-host → SaaS is the GTM upgrade path; **SaaS → self-host is the credibility move** — being able to leave with all data, for free, is what makes the compliance buyer trust you. Therefore export/import is **free core** (FR-PLAT-11/14); gating it would make the no-lock-in claim hollow. (Enterprise adds scheduled/automated backups on top.)
- **AD-PORT-3 — Offline snapshot + cutover; rebuild embeddings — for v1.** Migration is a transaction-consistent point-in-time export, transfer, import, and switch (briefly quiescing writes for the final cutover); live/streaming migration is deferred (§18). Embeddings are rebuilt on import (robust, embedder-agnostic — and on the SQLite tier the HNSW index is rebuilt from blobs by the same job); a carry-vectors fast path when the target embedder + version match is deferred (§18).
- **AD-PORT-4 — Logical export doubles as portable DR.** Distinct from physical backup/restore (`pg_dump` / SQLite-file-copy + blob backup), which is standard operator tooling we document; the logical export is the *portable* path and an input to the §16 DR posture.

---

## 15. Quality & evaluation architecture

> This section is the *testing/CI architecture* that hosts the EV spec, not a re-derivation of the EV design.

**Changed from the TypeScript edition:** the testing stack is **ExUnit + Ecto sandbox** (+ Testcontainers for Postgres) with `stream_data` property tests and port-level cassettes (replacing Vitest/fast-check); the determinism seam is now the ReqLLM provider layer; the injected `Clock` replaces direct `System`/`DateTime` calls. Benchmark replay targets (LongMemEval / LoCoMo / ConvoMem) and the two-tier split are unchanged. `bitcrowd/rag`'s eval metrics (groundedness / context-relevance / answer-relevance) are an additional in-tree signal.

- **AD-EVAL-1 — The model provider layer is the determinism seam.** Because every LLM call goes through the ReqLLM provider behaviour, tests inject a stubbed or replayed model adapter and *everything except the model call becomes deterministic* — gating, conflict, dedup, temporal logic, projection assembly, RBAC. This is the single biggest enabler of fast, deterministic CI and a direct payoff of the ports architecture (here, Ash + behaviours).

```
TWO TIERS, SPLIT BY DETERMINISM
PR / COMMIT GATE  (deterministic · fast · blocks merge)
  format · dialyzer/credo
  unit          pure domain logic (RBAC, tree, gates, temporal, dedup) — no model, Ecto sandbox
  data-layer    one contract suite run on BOTH AshPostgres + AshSqlite (Testcontainers for PG)
  contract      OpenAPI + generated-SDK + MCP surface conformance
  guardrails    cross-account isolation (property test); promotion/consent (crafted scenario + MOCKED model)
        └─ model provider stubbed / replayed from cassettes → fully deterministic
NIGHTLY / RELEASE  (live or pinned models · graded · reported separately)
  EV framework: scenarios + probes, golden set, judges, frontier sweeps, benchmark replay
  guardrail regressions BLOCK release; quality/cost/latency tracked vs the frontier
        └─ runs through the REAL surface + privileged internal probes
```

- **AD-EVAL-2 — Testing pyramid.** Unit (ExUnit) for pure domain logic; **data-layer conformance suites** — one contract suite run against *both* AshSqlite and AshPostgres, with **Testcontainers** for Postgres — guaranteeing the swap-ability invariant and catching backend behavioural divergence (EV-PERF-2) at unit level; contract tests against the AshJsonApi OpenAPI spec + generated SDKs + MCP; **`stream_data`** for property/invariant tests (cross-account isolation, EV-MET-3, is the canonical property); a **provider-level cassette layer** records/replays model I/O for deterministic, realistic pipeline tests. Ecto sandbox gives per-test transactional isolation on both backends.
- **AD-EVAL-3 — Two tiers by determinism.** The deterministic PR gate blocks merge; the EV framework runs nightly/on-release against live or pinned models (EV-REPRO-1), judges from a different model family (EV-GRADE-3). As many guardrails as possible are pushed into the deterministic gate; guardrail failures gate (EV invariant 1); quality/cost/latency are frontier-tracked. **Benchmark replay targets the public memory benchmarks** — LongMemEval [10] (knowledge-update, temporal-reasoning, and abstention abilities), LoCoMo [14] (multi-hop, temporal, adversarial recall over very long conversations), and ConvoMem [11] (abstention, temporal change, implicit connections; also the small-corpus full-context baseline that any memory system must beat to justify itself) — adapted through the real surface so reported numbers reflect the shipped path, not a harness shortcut. Credible numbers here are a stated marketing input (blueprint §15/§16), which is why replay lives in the release tier rather than a side repo.
- **AD-EVAL-4 — Bridge affordances the system must expose** (always-present-but-gated behind internal-only auth + config): an injected **`Clock`** everywhere time is read (**never call `System.system_time`/`DateTime.utc_now` directly**; enables EV-SCEN-5 and deterministic testing of the entire tri-temporal model, AD-DATA-1); a **manual "run dream-time now"** trigger (enqueue the Oban job on demand; EV-SCEN-6); **read-only internal probes** (Oban queue state, lifecycle, belief-time intervals, audit — EV-STRAT-4; mostly needed anyway for FR-GOV-21).
- **AD-EVAL-5 — The eval framework lives in-repo** (an `eval` OTP app / mix task tree), so scenarios and golden sets version-pin to the prototype and coverage tracks against the FRs (EV-REPRO-1, EV-STRAT-5).

---

## 16. Non-functional targets, SLOs & resilience

**Changed from the TypeScript edition:** the latency/throughput/availability/durability *targets and benchmarks are unchanged*. What changes is that **BEAM in-process concurrency, ETS/`persistent_term` projection caching, and in-VM assembly make them more comfortably achievable** — the `get_context` hot path has no network hop, and the sync fan-out is `Task.async_stream` across cores rather than RPC to a separate worker tier.

- **NFR-1 — Latency targets (measured, revisable — not hard gates).** These are targets the eval framework and benchmarks measure against (EV §7.4); they are revisited as data arrives, not frozen into the contract.

```
LATENCY TARGETS  (warm path · p95 · both backends unless noted)
  get_context        ~100ms  TARGET   excl. query-embedding (EV-MET-22/24) — measured, revisable
  check_readiness    ~100ms  tracked  reasoning-free, mostly DB
  query_knowledge    ~100ms  tracked  metadata filter (incl. as_of interval filter, FR-API-23)
  ingest (ack)       ~50ms   tracked  persist raw + Oban outbox job in one tx; extraction is async
  search             —       tracked  incurs query embedding (model) — reported separately
  ask                —       tracked  reasoning / multi-hop (EV-MET-25)
  cold start         —       tracked  measured, NOT gated (EV-MET-23)
```

- **NFR-2 — How the architecture serves the `get_context` target.** It is **reasoning-free** (FR-API-5) — no model call in the path; it reads **materialised projections + current-state** (AD-DATA-3), served from **ETS / `persistent_term`** with no synthesis and no ledger fold; ancestor merge is a **materialized-path prefix query** (AD-DATA-4); vector ANN + lexical are **co-located in the same DB / in-process** with proper indices (pgvector HNSW / in-memory hnswlib / FTS); the **query-embedding is excluded** (EV-MET-24), and `get_context` can even run embedding-free — ranking on the precomputed **salience × durability × recency** terms of the FR-API-10 scoring function (the retrieval triad of [3], with the expensive relevance term optional on this path). Because the whole path is in-VM with no network hop, the budget decomposes into EV-PROBE-5's stages, every one a fast in-process or DB op — this is where BEAM/ETS/in-process assembly makes the target *more comfortably achievable* than the TypeScript edition's cross-process assembly.
- **NFR-3 — No fan-out caps in v1.** `get_context` does full-path ancestor merge in v1; latency is measured (worst case: deep tree × large store × many cross-links, EV-PERF-3) and fan-out caps are reconsidered only if the data demands it (§18). This follows from treating the target as revisable rather than forcing a number with caps.
- **NFR-4 — Read scaling: replicas in queue-mode.** `get_context` and other reads route to Postgres **read replicas** to protect the latency target under read-heavy load and scale reads off the primary, accepting small replication lag — tolerable because projections are already async-refreshed (and often served from ETS) — with read-your-writes only where a flow needs it.
- **NFR-5 — Throughput is measured and frontier-tuned, not pre-committed.** Ingest, extraction, and dream-time rates come from the EV frontier sweep. The architecture makes them scale: identical clustered nodes scale horizontally (add nodes via libcluster), Oban absorbs bursts, per-scope budgets + shed-dream-time-first keep the system responsive under pressure.
- **NFR-6 — Availability.** Single-node (free): one BEAM node, **no HA** by design (laptop / single VM); RPO/RTO bounded by backup cadence + restart (though BEAM supervision means in-node crashes self-heal). Queue-mode (enterprise): identical nodes are HA by replication behind a load balancer; the **Oban cron leader** is the one non-HA-by-default component (outage delays scheduled dream-time only; leadership re-elects); the data tier (Postgres/S3) HA is the operator's responsibility via standard managed patterns. App-tier target ≈ 99.9%+ given an HA data tier — comfortably so, since any node can serve any request and supervision restarts failed components in-VM; the managed-SaaS SLA is a business decision on top.
- **NFR-7 — Durability / RPO.** The system of record is raw messages + validated knowledge + audit log; **RPO is a function of the DB replication/backup strategy** (operator-tunable; near-zero with synchronous replication). The queue (Oban), indices, HNSW cache, ETS caches, and projections are derived caches — losing them is never data loss; the reconciler rebuilds (AINV-5).
- **NFR-8 — Resilience & graceful degradation.** The standout property: a **model-provider outage degrades only the reasoning queries** — writes survive (ingest persists raw + inserts the Oban job in one tx and returns; extraction catches up) and **context-serving survives** (`get_context` touches no model); only `ask`/`search` degrade. With ingest-never-blocks-on-extraction, the transactional-outbox-as-Oban-insert, idempotent jobs, self-healing caches, and BEAM supervision isolating crashes, the failure posture is: under load or partial outage you lose *freshness or reasoning*, never *data* and never *the account wall* (enforced at edge + Ash policy + RLS regardless of partial failure). The DB is the one hard dependency; HA Postgres is the mitigation.
- **NFR-9 — Disaster recovery.** Two paths: physical backup/restore (DB dump + blob backup, documented operator tooling) and the **logical account export (AD-PORT-1) as a portable, cross-backend DR artifact**; queue-mode adds DB replication + S3 durability + a documented restore runbook.
- **NFR-10 — Scale ceilings (honest).** Single-node tops out at personal/small-team scale (one machine; SQLite single-writer serialisation; `Oban.Engines.Lite` is single-node only; hnswlib is RAM-bound — all consistent limits). Queue-mode scales to org level, with **shared Postgres as the eventual bottleneck** — read replicas (NFR-4) and schema/db-per-account (AD-DATA-6) are the levers; true sharding is a deferred far-scale concern (§18).

---

## 17. Recommended technology stack (concrete)

**Changed from the TypeScript edition:** this table is fully re-expressed for the Elixir/Ash stack.

| Concern | Choice | Notes |
|---|---|---|
| Language / runtime | Elixir on the BEAM | single language for the engine; heavy compute in the native NIF tier |
| Project layout | Mix umbrella / `boundary`-enforced contexts; Hex for publishables | Ash domain boundaries replace the hand-built layer cake |
| Boundaries | Ash domains + `boundary` compile-time checker | enforce the AD-TOPO-2 dependency rules |
| Domain / core | **Ash Framework** (Domains, Resources, Actions) | data layers *are* the adapters; actions are the typed op layer |
| Relational + migrations | **AshPostgres / AshSqlite** (Ash-generated migrations) | Postgres *and* SQLite; SQL-first control for pgvector/RLS/FTS |
| Storage (queue-mode) | Postgres + pgvector + PG-FTS | `:context` multitenancy + RLS keyed on Account |
| Storage (single-node) | SQLite + embedding-blob-of-record + FTS5 | one file; AshSqlite |
| Vector (enterprise) | **pgvector via `ash_ai` `vectorize`** | index write rides the transaction |
| Vector (free) | **in-memory HNSW (`hnswlib` NIF)** | blob column = source of truth; index = rebuildable cache; Nx brute-force fallback |
| Retrieval | one **`RetrievalStrategy` behaviour** (pgvector + HNSW adapters) | hybrid semantic + BM25/FTS fusion + optional rerank |
| Queue | **Oban (Postgres) / `Oban.Engines.Lite` (SQLite)** via **AshOban** | one job system both modes; **Redis removed** |
| Pipeline orchestration | **Ash.Reactor** (saga steps + compensation + idempotency keys) | triggered by AshOban |
| Transactional outbox | **Oban job inserted in the write transaction** | both engines; replaces outbox table + relay |
| Model layer | **ReqLLM** (ash_ai provider layer) | four roles; BYO-key; OpenAI-compat/Ollama/vLLM |
| Embedder | **`AshAi.EmbeddingModel` behaviour** → **Ortex/ONNX** default | bge-small / all-MiniLM; Bumblebee+EXLA for GPU; BYO-key API embedder |
| Multi-provider fallback | external proxy (e.g. LiteLLM) | deployment concern, not in-engine |
| RAG / ingestion | **`bitcrowd/rag`** | chunk / ingest / hybrid search / eval; pgvector-first, store swapped for HNSW tier |
| Doc extraction | **Extractous via `ExtractousEx` NIF** + **MDEx** | PDF/Office/email, Tika bundled in Rust — **no JVM/sidecar**; markdown→AST |
| Native (Rust/C) NIF tier | Extractous/MDEx (parse) · Ortex (embed) · hnswlib (ANN) | deliberate architectural layer |
| API contract | **AshJsonApi** (JSON:API + auto OpenAPI) | versioned `/v1/…` |
| Consumer SDKs | TypeScript + Python, generated from OpenAPI | AshGraphql omitted in v1 |
| MCP | **`ash_ai` MCP server** | reads + `ingest` as tools; governance NOT on MCP |
| Surfaces / realtime | **Phoenix** (HTTP + LiveView + Channels) + `Phoenix.PubSub` | governance UI is LiveView; realtime via `Ash.Notifier.PubSub` |
| Auth (free) | **AshAuthentication** | password / API-key / magic-link; owns its tables |
| Auth (enterprise) | **ExSaml or Samly** (SAML SP) + **assent** (OIDC) + SCIM over Ash | SP+IdP-initiated, SLO, multi-IdP; SCIM 2.0 implemented on Ash |
| AuthZ | **Ash.Policy.Authorizer + field policies** | OpenFGA / SpiceDB as a future enterprise ReBAC adapter [13] |
| Multi-tenancy | **Ash multitenancy** `:context`(+RLS) → `manage_tenant` → per-Account Repo | account derived from identity only |
| Observability | **OpenTelemetry Elixir + `:telemetry` + Logger** | vendor-neutral OTLP; off-by-default single-node |
| Product telemetry | PostHog | anonymous opt-out (self-host) / identified (SaaS) |
| Blob (cloud) | **ExAws** S3-compatible (MinIO for self-host) / local FS | per-account namespaces |
| Secrets (enterprise) | Vault / KMS | CMK at volume level (FR-PLAT-15); optional field-level via Ash type/change |
| Licence | **ed25519-signed token verified in Elixir** + entitlement module | offline-verifiable; n8n-style |
| Testing | **ExUnit + Ecto sandbox + Testcontainers + `stream_data` + provider cassettes** | deterministic PR gate |
| Eval framework | in-repo `eval` app | hosts the EV spec; replays LongMemEval / LoCoMo / ConvoMem [10, 14, 11] |
| Packaging | **single Mix release** image + compose (+ profiles); libcluster; Helm later | one image, role via runtime config |

---

## 18. Open & deferred decisions

Carried forward for explicit resolution (parallels FR §12 and blueprint §17). **Changed from the TypeScript edition:** several items are now **resolved** by the platform swap (marked ✅ RESOLVED); still-open items carry forward.

- ✅ **RESOLVED — Job queue.** Now **Oban via AshOban** (`Oban.Engines.Lite` on SQLite, Postgres engine in queue-mode); **Redis/BullMQ dropped**. One job system both modes.
- ✅ **RESOLVED — SQLite-tier vectors.** Now **in-memory HNSW (`hnswlib`)** with the embedding blob column as source of truth and the index as a rebuildable cache (replaces sqlite-vec).
- ✅ **RESOLVED — Default self-hosted embedder.** Now **Ortex (ONNX Runtime)**, bge-small / all-MiniLM class, behind `AshAi.EmbeddingModel`; Bumblebee+EXLA for GPU, BYO-key API embedder also supported (not licence-gated).
- ✅ **RESOLVED — Enterprise SSO library.** Now **ExSaml or Samly** for SAML SP + **assent** for OIDC (pick one SAML lib in the spike); free-tier auth is **AshAuthentication**. No hosted-auth dependency.
- ✅ **RESOLVED (path) — SSO/SCIM.** SCIM 2.0 is a **bounded build over Ash** (Users/Groups CRUD + filter), with OIDC-JIT provisioning as the early-customer fallback; scheduled for the paid milestone, no longer an architectural blocker.
- **ash_ai version pin & upgrade cadence** (v0.2.x is fast-moving; "lean in, isolate risk" — keep embedder + retrieval behind our own behaviours). *Set a pin + policy.*
- **RBAC Deny entries** — include explicit deny-wins ACEs for subtree exclusion (AD-SEC-3)? *Lean: yes; confirm.*
- **Free-licence middle-band features** — which otherwise-enterprise features the free registration unlocks (AD-CFG-5, AD-OBS-5). *TBD.*
- **Pricing unit** — seat / scope / account / flat (blueprint §17). *Open.*
- **`get_context` fan-out caps** — bound ancestor depth / cross-links to guarantee latency (NFR-3). *Deferred; revisit if measurements demand.*
- **Latency targets as gates** — the ~100ms set is currently a measured, revisable target (NFR-1); whether to harden any into a release gate later is open.
- **Durable-execution orchestration adapter** — Temporal / DBOS beyond Ash.Reactor + Oban (AD-PIPE-1). *Deferred; not adopted — Reactor + Oban suffice.*
- **HNSW persistence policy** (AD-DATA-5, AD-SEAM-4.1) — snapshot cadence + boot-rebuild + reconcile-from-blobs tuning. *Confirm in the vector spike.*
- **Reranker default** — model cross-encoder vs fusion-only (AD-SEAM-3, AD-MODEL-1). *Lean: fusion-only default; confirm.*
- **Live/streaming migration** (AD-PORT-3). *Deferred; offline snapshot for v1.*
- **Carry-vectors fast path on import** when embedder matches (AD-PORT-3). *Deferred; rebuild for v1.*
- **Per-scope model-role overrides** (FR-API-18, FR §12). *Deferred; account-level for now.*
- **AshGraphql surface** for rich clients (AD-API-3). *Deferred; JSON:API + OpenAPI only in v1.*
- **ETS/`persistent_term` projection cache invalidation** in queue-mode (NFR-2, NFR-4) — cross-node invalidation via PubSub. *Confirm mechanics.*
- **Leader-election for scheduler HA** beyond Oban's built-in mechanism (AD-DEPLOY-4). *Deferred; Oban cron leader for now.*
- **Postgres sharding** for far-scale (NFR-10). *Deferred.*
- **Full sensitivity × assurance matrix** (AD-GOV-3). *Deferred; allowlist + floor for now.*
- **External vector-DB adapter** (eventual-consistency Oban path, AD-SEAM-4.4). *Deferred.*
- **Structured knowledge-graph layer + graph retrieval strategy** (AD-SEAM-3, FR §12). *Deferred; seam reserved in `RetrievalStrategy`.*
- ~~**Working title / product name.**~~ *Resolved: **Cartulary** (v1.0).*

---

## 19. References

Cited inline as `[n]`. The FR spec (§13) carries the fuller, design-level bibliography; this list covers the references load-bearing for *architectural* decisions. (Unchanged from the TypeScript edition — these are research/precedent citations, not platform choices.)

1. Rasmussen, P., Paliychuk, P., Beauvais, T., Ryan, J., Chalef, D. *Zep: A Temporal Knowledge Graph Architecture for Agent Memory.* 2025. arXiv:2501.13956. — bi-temporal edge dating and invalidation-not-deletion (Graphiti); the convergent precedent for AD-DATA-1.
2. Chhikara, P., Khant, D., Aryan, S., Singh, T., Yadav, D. *Mem0: Building Production-Ready AI Agents with Scalable Long-Term Memory.* ECAI 2025. arXiv:2504.19413. — two-phase extract/update pipeline; the production precedent for the fast lane (AD-PIPE-2).
3. Park, J. S., et al. *Generative Agents: Interactive Simulacra of Human Behavior.* UIST 2023. arXiv:2304.03442. — relevance × recency × importance retrieval scoring (NFR-2, FR-API-10).
4. Lin, K., Snell, C., Wang, Y., Packer, C., Wooders, S., Stoica, I., Gonzalez, J. E. *Sleep-time Compute: Beyond Inference Scaling at Test-time.* 2025. arXiv:2504.13171. — offline reasoning over persistent context cuts test-time compute ~5×; the quantitative case for the dream-time/serving split (§1, AD-PIPE-2).
5. Xu, W., et al. *A-MEM: Agentic Memory for LLM Agents.* 2025. arXiv:2502.12110. — memory evolution / dynamic link maintenance (the dream-time relation-upkeep step, AD-PIPE-1).
6. Sumers, T., Yao, S., Narasimhan, K., Griffiths, T. *Cognitive Architectures for Language Agents (CoALA).* TMLR 2024. arXiv:2309.02427. — the episodic/semantic/procedural/working taxonomy mapped in FR §1.
7. Packer, C., et al. *MemGPT: Towards LLMs as Operating Systems.* 2023. arXiv:2310.08560. — context paging and budget discipline (FR-API-10).
8. Zhong, W., et al. *MemoryBank: Enhancing Large Language Models with Long-Term Memory.* AAAI 2024. arXiv:2305.10250. — Ebbinghaus forgetting-curve decay (AD-DATA-2).
9. Zhang, Q., et al. *Agentic Context Engineering: Evolving Contexts for Self-Improving Language Models.* 2025. arXiv:2510.04618. — context collapse under monolithic rewriting; incremental delta updates (AD-PIPE-7).
10. Wu, D., et al. *LongMemEval: Benchmarking Chat Assistants on Long-Term Interactive Memory.* ICLR 2025. arXiv:2410.10813. — replay target; abstention and knowledge-update abilities (AD-EVAL-3, AD-MODEL-3).
11. Pakhomov, E., et al. *ConvoMem Benchmark: Why Your First 150 Conversations Don't Need RAG.* 2025. arXiv:2511.10523. — replay target; the full-context baseline a memory system must beat (AD-EVAL-3).
12. Snodgrass, R. T. *Developing Time-Oriented Database Applications in SQL.* Morgan Kaufmann, 1999. — the bi-temporal valid-/transaction-time model (AD-DATA-1).
13. Pang, R., et al. *Zanzibar: Google's Consistent, Global Authorization System.* USENIX ATC 2019. — relationship-tuple authorization; the ReBAC adapter path (AD-SEC-3).
14. Maharana, A., et al. *Evaluating Very Long-Term Conversational Memory of LLM Agents (LoCoMo).* 2024. arXiv:2402.17753. — replay target (AD-EVAL-3).

---

*End of v1.0, Elixir/Ash edition. Supersedes the TypeScript edition for the how-it's-built layer; product semantics, invariants, gates, temporal model, and NFR envelope are unchanged. Pairs with the FR spec (the requirements it realises) and the EV spec (the framework that validates it). `AD-*`, `NFR-*`, and `AINV-*` ids are stable anchors for review and traceability.*
