# Cartulary — Multi-Scope Agent Memory System — Product Blueprint

> **Status:** v0.2 (Elixir/Ash edition). Companion to `memory-system-functional-requirements.md` (the FR spec — technical source of truth), `memory-system-architecture-and-nfr.md` (the ARCH spec), and `memory-system-build-phasing.md` (the PH plan — engineering phasing); this blueprint is the *why / who / how-it-reaches-people / how-it-makes-money* layer above them.
> **Audience & purpose:** an internal **north-star** and an **onboarding brief** for engineers and OSS contributors. Not an investor deck — no market-sizing theatre; the focus is a clear, opinionated picture of what we're building and the bet behind it.
> **Product name:** **Cartulary** — the bound register in which an institution kept authenticated copies of its charters; here, the governed register of what an organisation knows. *Multi-Scope Agent Memory System* remains the descriptive subtitle.
> **Elixir/Ash edition — read first.** The implementation platform is now **Elixir + the Ash Framework** (BEAM runtime, Phoenix, Oban), not TypeScript/Node. **The product strategy is unchanged** — vision, ICPs, the two moats, GTM funnel, competitive positioning, open-core/fair-code split, pricing philosophy, and roadmap all carry over verbatim. This edition only refreshes the concrete *implementation* references (stack, deployment topology, queueing); the business bet is identical. Pairs with the Elixir/Ash editions of the FR and ARCH specs.

---

## 1. Executive summary

A self-hostable, model-agnostic **memory layer for AI agents** — but where the rest of the field stops at remembering *a user*, this remembers *an organisation*. Memory lives in a **recursive scope tree** (a company and its nested teams/projects), and individual knowledge is promoted up to shared scopes only through **human-governed gates**. The same engine powers three shapes of the same problem — a personal agent's brain, a SaaS product's per-customer memory, and a company-wide governed knowledge base — distinguished only by how deep the scope tree goes and how much human governance is dialed in.

The bet: as agents shift from *chatting* to *doing work*, the scarce resource stops being raw recall (now table stakes) and becomes **trustworthy collective knowledge with guardrails** — knowledge an organisation can stand behind. No surveyed competitor owns that lane. We start lean and open-source to win developers and earn brand, then monetise the enterprise shape.

## 2. Problem & why now

Three things are true at once:

- **Agents forget.** Stateless models treat every session as a blank slate; stuffing history into the context window is expensive, noisy, and mixes stale facts with current ones. A dedicated memory layer is now an accepted part of the stack.
- **Organisational knowledge is fragmented and ungoverned.** The hard-won context — why a decision was made, what a customer prefers, how a team actually operates — lives in people's heads and dies at session and team boundaries. When agents start *acting* on that knowledge rather than just surfacing it, "who vouches for this, and how did it change?" becomes a real question.
- **The memory field is consolidating into table stakes.** Temporal handling, conflict-invalidation, multi-store retrieval, and prompt-ready context are converging across every vendor (Honcho, Zep, Mem0, Letta, Cognee, Hindsight). The race to remember *a user* is crowded and commoditising.

**Why now:** the gap nobody is filling is *collective, governed* memory — memory above the individual that a human can review before it becomes shared truth. As autonomy rises, the willingness to let an agent act on unvetted memory falls, and **self-hostable + auditable + human-gated** becomes a buying requirement, not a nice-to-have.

## 3. Vision & north star

**Memory that scales from one person to a whole organisation, on one engine.**

In three years: a developer plugs us into their personal agent in five minutes and it finally remembers them across projects. They reach for the same tool at work to give their AI product per-customer memory with guardrails. Their company adopts it as the governed knowledge base that every internal agent and employee shares — the system of record for *what the organisation knows and believes*, with provenance, validation, and an audit trail. One engine, growing with the customer the whole way up.

## 4. The spine: one engine, three shapes

Everything below follows from a single idea — the three target use cases are not three products, they are **the same scope-tree engine at three depths of collective complexity**:

| Shape | Account = | Scope tree | Peers | Governance dial |
|---|---|---|---|---|
| **Personal-agent brain** | one person | depth ~1 (you + a few projects) | you + your agent(s) | light — you are your own curator |
| **SaaS product memory** | the SaaS vendor | per-customer / per-product-area | end users + the product's agent | guardrails — consent gate, sensitivity, provisional-vs-held |
| **Organisational KB** | the company | the full org tree (divisions → teams → projects) | employees + internal agents | full — validation queue, curators, audit, compliance |

The recursive scope tree, governed promotion, and reasoned-knowledge model are *identical* across all three; only depth and the governance threshold change. This is the product's biggest structural advantage: a customer can **grow from shape to shape inside the same tool**, and — crucially — each shape is the natural distribution path to the next (§12).

## 5. Target users & ICP

- **Personal-agent brain — indie developers and agent tinkerers** building on openClaw, Hermes, Claude Code, and the MCP ecosystem. They adopt for themselves, for free, and become the word-of-mouth top of the funnel.
- **SaaS product memory — AI-native product teams** who want to ship personalised, stateful experiences with guardrails and *won't* hand their users' data to a closed cloud. Often the same developers, now at work.
- **Organisational KB — governance-sensitive mid-to-large organisations** (regulated industries — finance, health, legal — and engineering orgs with compliance needs) where self-host + human-gated promotion + audit is the reason to buy. This is the monetisation anchor.

The three are a **funnel, not three separate go-to-markets**: personal adoption seeds the brand, pulls through to SaaS embedding, and lands inside the companies that eventually need the enterprise shape.

## 6. Value proposition & differentiation

**What we match (table stakes — necessary, not a moat):** temporal handling, conflict-invalidation-not-overwrite, hybrid retrieval, prompt-ready context assembly, multi-tenant isolation, model-agnosticism, and eventually competitive benchmark numbers.

**What is ours (the moats):**

1. **A recursive scope tree with human-governed upward promotion** — collective memory above the individual, where knowledge flows up only through a review gate. Almost everyone else is flat (user / session / agent); the one player doing governed org-memory (Augment "Cosmos") is closed, single-level, and not self-hostable.
2. **Skill-readiness self-evaluation** — before an agent runs a skill, the system checks it actually *has* the knowledge that skill needs, and elicits it if missing. No surveyed competitor does this; it is the guardrail that makes agents safe to let *act*.

**Plus two positioning advantages:** **self-hostable + fair-code** (the org-KB buyer wants their knowledge on their own infrastructure; the indie dev wants no lock-in), and **model-agnostic** (works with any provider, including self-hosted). The self-host story is stronger still on this platform: a **lower operational surface** — no Redis, no separate worker fleet, embeddings that can run **local and offline** — means the buyer runs less, and keeps their knowledge (and inference) entirely on their own infrastructure.

The strategic one-liner: **solve institutional knowledge first — personalisation falls out of the same engine for free, and we don't have to re-platform when agents move from answering questions to doing work.**

## 7. Competitive landscape (condensed)

The field splits by philosophy: agent-self-managed memory (**Letta / MemGPT**), peer-centric reasoning memory (**Honcho** — our conceptual ancestor), temporal knowledge graphs (**Zep / Graphiti**, **Cognee**), lightweight vector recall (**Mem0**, **Supermemory**), and multi-strategy-retrieval newcomers (**Hindsight**). All are converging on the same table-stakes feature set amid a clear consolidation wave. Closest partial overlaps to *us*: Cognee recently shipped a *flat* org/agent/user split, and Augment "Cosmos" gates org-memory writes behind human review but is closed and single-level. Nobody combines the **recursive governed scope tree** with **skill-readiness** — that intersection is our lane. (Full analysis lives in the competitive-research notes.)

## 8. Product principles (non-negotiables)

The eight invariants from the FR spec, restated as promises every contributor upholds:

1. **Context flows down freely; knowledge flows up only through a governance gate.**
2. **Agents submit observations only; the pipeline is the sole writer of knowledge.**
3. **Blast radius scales the bar** — the wider a fact's exposure, the higher the bar to attribute it there.
4. **Knowledge is the only atom;** profiles, scope cards, and summaries are projections of it.
5. **Reasoned artifacts pass validation gates; authored artifacts use plain versioning.**
6. **Belief-time ≠ valid-time ≠ salience; confidence ≠ sensitivity; subject ≠ source.**
7. **Everything scoped inherits down the tree, nearest-wins.**
8. **Cross-account isolation is absolute.**

Two cultural commitments on top: **self-hostable and fair-code by default** (the engine is never held hostage to our cloud), and **model-agnostic always** (we never assume a provider).

## 9. Scope — what it is, and what it is *not*

**It is** a memory layer: a reasoning pipeline that turns raw interactions into governed knowledge, plus a context-assembly and query surface (MCP + SDK) that serves it back.

**It is not:**

- **an agent framework** — we never run your agent or own its loop (contrast Letta); we supply context, you bring the model.
- **a vector database** — we sit *above* the store and stay pluggable over pgvector (Postgres) or SQLite + in-memory HNSW.
- **a closed cloud or a model provider** — the core is self-hostable and provider-neutral.
- **a general document-RAG tool** — retrieval serves the memory; reasoned knowledge is the point, not chunk search.

## 10. Capability pillars

(Feature-level; the FR spec is authoritative for detail.)

- **Scope tree & inheritance** — recursive org/team/project containment; context inherits down, nearest-wins.
- **Reasoned knowledge + projections** — natural-language knowledge as the atom; profiles, scope cards, and session summaries as projections (renderable through scope and observer/provenance lenses).
- **Two-stage pipeline** — cheap ingest-time extraction + periodic "dream-time" reasoning (deductions, contradiction/supersession, corroboration-leveling, pattern surfacing).
- **Governance** — two-gate validation, a curator queue, sensitivity + consent, proportionate right-to-be-forgotten, immutable audit, and a knowledge-history / diff view.
- **Temporal model** — expiry, revalidation, salience windows, system-derived belief-time, and point-in-time ("what did we know on date D") queries.
- **Skill-readiness** — authored requirement cards drive a pre-flight gap report and elicitation.
- **Retrieval** — hybrid semantic + lexical with reranking; provenance / source filtering.
- **MCP interface + harness SDK** — reads + ingest over MCP (governance off-surface); a thin, provider-agnostic SDK.
- **Deployment** — single-node (free: SQLite + in-memory HNSW + FTS5, in-process Oban, no Redis) and clustered queue mode (enterprise: Postgres + pgvector + Oban across N Elixir/Phoenix nodes) behind **one Mix release**, role selected at runtime; docker-compose self-host with no Redis.

## 11. Architecture at a glance

The core loop: **observe → extract (fast) → reason (dream-time) → gate → project → serve.** Agents and connectors submit raw observations; a cheap extractor mints proposed knowledge; a stronger periodic reasoner deduces, reconciles conflicts, levels by corroboration, and refreshes projections; humans validate at the gates; agents consume precomputed, reasoning-free context via `get_context` (plus `ask` / `search` / `query_knowledge` / `check_readiness`). Elixir/Ash throughout, with Phoenix surfaces (HTTP + LiveView); a pluggable model behaviour (over ReqLLM) abstracts four model roles; Postgres + pgvector or SQLite + in-memory HNSW behind one Ash data-layer interface; **Oban** runs the jobs in both modes (Postgres engine in queue mode, `Oban.Engines.Lite` on SQLite single-node) — the Redis + BullMQ queue is gone, so there are fewer moving parts to self-host. (FR spec §7, §11 for detail.)

## 12. Go-to-market & distribution

**Motion: bottom-up, open-source-led.** The funnel *is* the three shapes:

1. **Top of funnel — personal-agent plugins.** Free, self-hostable, drop-in integrations for openClaw, Hermes, Claude Code, and any MCP host. Developers adopt for themselves; this is where brand and word-of-mouth are won.
2. **Middle — SaaS embedding.** Those developers reach for the same tool at work to add memory to their AI products. Still free self-host; some convert to the managed offering or enterprise.
3. **Bottom — enterprise capture.** The companies those products live in adopt the governed org-KB shape; the enterprise tier (multiple Accounts, queue mode, SSO/SCIM, per-account isolation, audit export) is the monetisation event.

**Channels:** GitHub + excellent docs; the integration / MCP ecosystem; and a point-of-view content stream that *defines the category* — "why RAG isn't memory," "why memory needs governance," "collective vs personal memory." **Brand goal:** become the name people say for *governed, collective memory*.

## 13. Business model & pricing

**Open-core / fair-code (n8n Sustainable-Use-License style).**

- **Free self-host core** — the full engine, MCP, SDK, single-node mode, basic RBAC, self-hosted models (including **local/offline embeddings via Ortex/ONNX** — zero-egress, zero-cost inference for the privacy- and cost-sensitive self-hoster). Single Account, unlimited use. No metering — you run it.
- **Enterprise license** — multiple Accounts, all of queue mode, SSO/SAML + SCIM, db/schema-per-account isolation, granular RBAC, audit export, CMK / compliance.
- **Managed SaaS (later)** — we host it for teams who don't want to.

**Pricing philosophy: simple and predictable, never token-metered.** We're building this partly *because* context-window economics are unpredictable; our pricing should embody the opposite. Concretely (strawman, §17): enterprise as a **flat annual license banded by scale** (e.g., by seats or Accounts) — a line item a buyer can predict; managed SaaS as a **small number of legible plan tiers** with generous ceilings rather than per-unit billing. The exact unit (seat / scope / Account / flat) is an open decision; the rule is that it must be legible to the buyer and roughly track the value they get — not their token spend.

## 14. Roadmap & phasing

The business phasing mirrors the product phasing:

- **Phase 1 — Lean OSS / win developers.** Single-node MVP proving the core loop (ingest → extract → dream-time → governed `get_context`), plus the personal-agent integrations. *Goal: adoption + brand.* No revenue yet.
- **Phase 2 — First customers.** Queue mode and the governance UI matured enough for design partners on the SaaS-product and early org shapes; first enterprise licenses. *Goal: design partners → first paid contracts → early ARR.*
- **Phase 3 — Scale / funding.** Enterprise tier and managed SaaS hardened (SSO/SCIM, compliance, per-account isolation); raise on demonstrated ARR. *Goal: ARR growth and category leadership.*

This is the *shape* of the plan; the detailed engineering phasing lives in `memory-system-build-phasing.md` (PH-0–PH-7, mapped back to these business phases in its §5). **Execution model:** Cartulary is built by AI coding agents through an automated development framework (PH-0), orchestrated via GitHub and a ticket tracker, with a human as reviewer and merge gate and Telegram as the process channel. The Elixir talent pool is smaller than TypeScript's, but that is offset here rather than incurred: the code is written by AI agents, and the BEAM's supervision and concurrency model removes whole classes of infrastructure (no Redis, no separate worker fleet, no RPC fan-out layer) that a human team would otherwise have to build and maintain.

## 15. Success metrics

**North star: a sustainable business — ARR — and brand recognition as *the* governed/collective memory layer.** Benchmarks and logos are *marketing inputs* to those, not goals in themselves.

Phase-gated leading indicators:

- **Phase 1:** active self-host installs, contributor count, breadth of integrations, and category mindshare (are we in the comparison articles, and on the right side of them?). Benchmark numbers and early logos serve here — as marketing fuel.
- **Phase 2:** signed design partners → first paid contracts → early ARR and retention/expansion among them.
- **Phase 3:** ARR growth, net revenue retention, and durable category leadership (we're the default answer for governed/collective memory).

## 16. Risks & assumptions

- **Consolidating market.** The table-stakes features are commoditising fast; we must lead with the two moats, not re-implement commodity memory. (Build phasing should front-load the differentiators.)
- **Focus risk.** "One engine, three shapes" is a strength for the *product* but a trap for a lean *go-to-market*. Mitigation: sequence the funnel — win developers/personal first, monetise enterprise later — rather than chasing three markets at once.
- **Governance vs. latency.** Human-gated promotion buys trust at the cost of time-to-shared-knowledge. The provisional peer-level path and the auto-accept matrix are load-bearing for the personal and SaaS shapes and must be built and tuned early, not deferred.
- **The credibility bar.** Incumbents advertise sub-200ms retrieval and 90%+ benchmark accuracy; even though benchmarks are "just marketing," we have to be in the same ballpark to be taken seriously.
- **Funnel assumption.** The whole GTM rests on personal/dev adoption actually pulling through to enterprise. If it doesn't, monetisation stalls — watch for this early.
- **Enterprise build cost.** The org-KB shape needs a real governance UI (Phoenix LiveView over the same Ash resources), SSO/SCIM (SAML via ExSaml/Samly, with SCIM a bounded, well-specified build over Ash), and compliance work the OSS core doesn't — a meaningful investment before Phase-2 revenue.
- **Young platform dependencies.** Some Elixir/Ash building blocks we lean on are early-stage (e.g. `ash_ai`, the in-memory HNSW binding). Mitigation: keep the embedder and retrieval strategy behind our own behaviours so a fast-moving dependency can be swapped without touching the product surface.

## 17. Open decisions (pending)

- **Wedge sequencing** — *strawman:* developer/personal-led adoption first, enterprise monetisation later, with the product serving all three shapes throughout. (You were undecided; this is the proposed default — confirm or steer.)
- **Pricing unit** — predictable tiers agreed; the exact unit (seat / scope / Account / flat) is open.
- **Enterprise SSO library** — SAML via **ExSaml vs Samly** (both SP+IdP-initiated) to be picked in the implementation spike; **SCIM** scoped as a bounded Phase-2 build over Ash (or OIDC just-in-time provisioning for the earliest design partners) — no longer an architectural blocker.
- ~~**Naming**~~ — *resolved: **Cartulary**.*
- ~~**Platform**~~ — *resolved: **Elixir + Ash** (BEAM, Phoenix, Oban); Redis/BullMQ dropped, SQLite vectors via in-memory HNSW, embeddings can run local/offline via Ortex/ONNX. See the Elixir/Ash redesign & decision list.*
- ~~**Engineering build-phasing**~~ — *resolved: `memory-system-build-phasing.md` (PH-0–PH-7); its remaining dependency is the PH-0 framework design document (next).*

---

*End of v0.2 product blueprint (Elixir/Ash edition). Pairs with the FR/ARCH specs and the build-phasing plan; keep them in sync as decisions evolve.*
