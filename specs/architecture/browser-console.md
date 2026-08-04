<!-- SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0 -->

# Browser Console

Status: implemented

The browser console exposes human read and self-governance without adding a
writer, authorization model, or visibility definition.

It implements the human-surface obligations of `FR-UI-1` through `FR-UI-4`,
`FR-KN-9`, `FR-KN-14`, `FR-GOV-3`, `FR-GOV-8`, `AD-SEAM-2`, `AINV-2`,
`AINV-4`, `AINV-7`, `AINV-8`, and `NFR-9`, and it is bound by the entity-cache
non-exposure rule of `AINV-6`.

## One browser surface

One console keeps decisions beside provenance, lifecycle, conflicts, and raw
observations without duplicating panels across applications.

`/governance` keeps its stricter mount hook and shared frame. Its route, module,
events, and heading remain unchanged because
`test/cartulary/f4_real_gate_a_b_governance_test.exs` and
`test/cartulary/f9_skill_readiness_procedural_memory_test.exs` assert on all
four. The console's per-statement page offers the same decisions through the
same operation-layer calls; the queue remains the place for working a backlog,
including the bulk actions that only make sense there.

`GovernanceLive.Index` batch-resolves authorized `conflict_knowledge_ids` and
drops unresolved ids. Checkbox selection is local `@selected_ids` render state;
bulk selection targets only already-visible rows.

## Layering

| Module | Owns |
| --- | --- |
| `CartularyWeb.ConsoleAuth` | Mount-time authentication: valid session token, password identity kind. No role check. |
| `CartularyWeb.GovernanceAuth` | The same, narrowed to `curator` and `account-admin`. Unchanged. |
| `CartularyWeb.SessionController` | `/sign-in` for any human role; `/sign-out`; the bare-origin redirect. |
| `CartularyWeb.Console.Access` | The two visibility rules and the action gates. Pure. |
| `CartularyWeb.Console.Loader` | Every database read the console performs. |
| `CartularyWeb.Console.Graph` | Deterministic radial layout. Pure. |
| `CartularyWeb.ConsoleComponents` | Shell, navigation, tiles, badges, tables, panels, tabs, filter chips, pager, disclosures. Stateless. |
| `priv/static/assets/governance.js` | The whole client: the LiveView socket and the `Copy` hook. Hand-written, same-origin, no bundler. |
| `CartularyWeb.ConsoleLive.Tools` | Forms for the MCP allowlist; dispatches the same non-persisted Ash actions and renders the latest result. |
| `CartularyWeb.ConsoleLive.*` | Ten pages: rendering and event dispatch only. |

Both browser surfaces retain the historical `governance_token` session key so
one sign-in opens both and existing sessions remain valid.

## Visibility

Ash policies and row-level security decide Account and scope before the console
is consulted. Two further rules are lifecycle-shaped, which policies cannot
express, and both live in `Access` so that no page can widen them
independently. Both are narrowing; neither can grant access to a scope the
actor's grants do not already reach.

**Provisional:** `state != "provisional" or subject_peer_id == <viewer>`.
`Cartulary.Retrieval.Store` uses the identical condition; divergence is a leak.

**The governance-state rule.** Curators and account admins see every lifecycle
state. Members and readers see `active`, `needs_revalidation`, `expired`, and
`superseded`, plus any state at all when the statement's subject is themselves.
The self-view exemption mirrors the `KnowledgeItem` read policy, which already
authorizes a subject regardless of scope, and it is what makes contest, redact,
and erasure reachable rather than theoretical.

Both rules are compiled into the query rather than applied to loaded rows, so
paging is correct: a page never comes back short because rows were discarded
after the fact. `Access.visible_knowledge?/2` is the in-memory twin, used only
where rows arrive from an operation-layer call.

## Reads that refuse rather than filter

Ash filter checks narrow a read; simple checks reject it. Four console-relevant
resources are guarded only by simple role checks — `GateDecision`, `GateRule`,
`UsageEvent`, `PipelineRun` — so reading them as a member raises
`Ash.Error.Forbidden` instead of returning an empty list. Every such read is
gated by `Access.can?/2` before it is issued, and the operations page performs
its role check before its first query rather than after. Removing either guard
converts a polite decline into a crash.

## Writes

The console implements no direct durable write. Each gesture forwards to an
existing operation:

| Gesture | Operation |
| --- | --- |
| Approve, reject, defer, edit-as-replacement, merge | `Governance.Engine.decide/4` |
| Bulk decisions (queue only) | `Governance.Engine.bulk_decide/4` |
| Promotion request | `Governance.Engine.request_promotion/3` |
| Confirm, contest, redact | `Governance.Engine.contest/3` |
| Consent grant or deny | `Governance.Engine.subject_consent/6` |
| Erasure | `Governance.Erasure.request/3` |
| Skill card publication (queue only) | `Skills.publish/2` |
| Raw observation submission (tool workbench) | `McpTools.ingest` Ash action |
| Own inline-answer resolution (tool workbench) | `McpTools.resolve_validation` Ash action |
| Own ask-limit tightening (tool workbench) | `McpTools.set_ask_preference` Ash action |

A rendered control is presentation, never authorization: the operation layer
re-checks the actor, so a forged event from a hand-crafted client is refused
there. Refusals and bad hand-typed input are rescued into a flash with one
generic message, so error text cannot be used to probe for which identifiers
exist.

Consent grants are submitted with `verified: true` because a password browser
session authenticated the person answering. That flag is a statement about the
channel, not a convenience — passing it from a channel where it is untrue would
defeat the operation layer's check.

Erasure is confirmed by typing a literal word. It runs immediately and cannot
be undone, so a single-click control would be a defect.

The tool workbench mirrors the eight-action MCP allowlist. It calls
`Ash.run_action/2` with the signed-in human actor, accepts only each action's
declared arguments, and renders the returned value as JSON. It cannot
select an Account or calling peer. Read actions retain scope filtering and
best-effort inline-question attachment. No curator or bulk action is present.

Presentation groups the cards by intent — retrieve, operate, evaluate — and a
page-wide context supplies the session and scope that most cards need, with a
per-card override. Grouping and labelling are presentation only: the submitted
arguments remain each action's declared arguments, and no argument is inferred
from a group. The acknowledgement checkbox on a state-changing card is likewise
a browser affordance, because the operation layer re-authorizes the write.

A result is summarized before it is dumped. The summary reads keys the rendered
payload actually carries and omits a row rather than inventing a default, and
that payload stays on the page, so the summary can never become a second source
of truth. The only key the browser adds is `retrieval_health` on `search` and
`ask`; it is atom-keyed to stay distinguishable from the action's own
string-keyed value, and belongs to no contract. A bounded run history lives in
the LiveView only; nothing about a run is persisted, logged, or carried into
telemetry.

### Retrieval diagnostic mode

The workbench carries one control that is not a tool. Diagnostic mode
reproduces retrieval behaviour for an account administrator by calling
`Memory.diagnostic_search/2`, which re-authorizes the caller and owns the
options; the LiveView also refuses the event, so neither check depends on the
other. Ordinary `search` and `ask` keep their published defaults, and the mode
adds no route, MCP tool, or HTTP field.

Naming strategies, disabling the deadline, and forcing reranking are the
internal seam of `AD-SEAM-3`, not public contract. They are unlocked by a
`Retrieval.DiagnosticGrant` struct travelling in the facade's filters: decoded
JSON cannot produce a struct, so the same facade reached over HTTP cannot forge
one, and a plain map under the same key is ignored. A grant changes which
strategies run and how long they may take; it never changes Account, scope,
lifecycle, or subject filtering, so it discloses nothing the caller could not
already read. The candidate limit is clamped, because a browser form must not
be able to ask for an unbounded pre-fusion pool.

Diagnostic results are rendered apart from tool runs and labelled as not
production-equivalent, since a run with an isolated strategy or no deadline is
evidence about retrieval rather than a better answer. The page reports how many
candidates rank below the ordinary window without claiming any of them is
correct, and reports honestly when only scope-ranking strategies contributed.

Query-term highlighting returns plain segments rather than markup, so the
template escapes statement text on the ordinary path. The copyable request is
built from an allowlist — scope, query, profile, limit, and diagnostic options —
so a field added to the form later cannot leak a session id, credential, or
Account identifier into an export by omission.

## Non-exposure

The console renders statements, raw observations, and document titles because
an authorized person must be able to read them in order to judge them. It never
renders:

- **entity rows or entity mentions** — canonical names, aliases, surface forms,
  and entity identifiers. Their rows span every scope that mentioned a name, so
  drawing them would carry names across the boundary the scope tree exists to
  keep. Their read actions are pipeline-only, so an accidental query fails
  loudly rather than leaking;
- **embedding vectors and chunk contents** — rebuildable caches; counts and
  identities only;
- **password hashes, API key hashes, connector secrets, blob bytes.**

Reader projection does not create an exception for entities. Deriving a label
only from visible statements would avoid returning stored aliases, but grouping
those statements would still disclose the resolver's conclusion that they
share a referent. It would also turn a pipeline-only resource into an
actor-specific live query whose safety depends on every policy and resolver
change. Curator investigations therefore remain statement-shaped: scoped
retrieval followed by the visible provenance, supersession, and relations on a
statement page.

Rendered text never enters logs, telemetry, audit entries, or job arguments.

The entity non-exposure rule permits two content-free diagnostics. The
account-admin operations page receives only Account-wide counts, rates,
quantiles, and alias-count buckets from the reviewed retrieval store. Statement
detail receives only a count and capped ids of other statements sharing an
entity after the store applies the reader's authorized scopes and console
lifecycle rules; the loader then reads those statements through ordinary Ash
policies. Entity ids, names, aliases, surface forms, and mention rows never
reach a LiveView.

## Explorer information architecture

Browsing and retrieval answer different questions, and presenting them in one
flow made each read as a qualified version of the other. They are now modes.
Browse never issues a search, so the ranked path costs nothing when nobody asked
for it; find leads with the query and keeps the exhaustive list beneath the
ranked preview, because a ranking miss is not evidence of an empty memory.

Mode, filters, sort, page, and page size all live in the URL. That makes a view
linkable and the browser's own history correct, and it is what lets the
statement page return to the list the reader left. A statement link carries the
current query string as `back`; the detail page rebuilds a return path from the
explorer's own filter keys and discards everything else, so `back` can never
name a destination outside the explorer.

The scope picker is a native `input`/`datalist` rather than a JS combobox.
Generated scope trees are large enough that a flat `select` is unusable, and a
`datalist` gives typeahead with no script, which `script-src 'self'` makes the
deciding factor. Free text is safe because an unknown path narrows to nothing in
`subtree_scope_ids/2` rather than widening.

`Loader.knowledge_list/2` clamps page size to an offered set, rejects an unknown
sort, and clamps an out-of-range page to the last one. The bound on page size is
the same judgement as `@panel_limit`: a reader who wants every row wants the
portability archive.

The retrieval preview renders `Memory.search/2`'s published payload — flattened
string-keyed records carrying `rrf_score` and `strategies`, with fused order
expressed as position because strategy-local scores are incomparable. It applies
no further lifecycle narrowing, because `Retrieval.Store` returns `active` plus
the caller's own `provisional` and nothing else, which is strictly narrower than
what any console role may see. Widening the store would make that untrue.

Badges carry a shape as well as a colour, so lifecycle and sensitivity never
depend on colour alone, and a legend gives each value one sentence of meaning.
Tables whose cells carry `data-label` opt into a card layout below 900px; the
rest keep a labelled `overflow-x` region, so the page body never scrolls
sideways.

The statement page is ordered by the reader's questions — claim, available
actions, currency and trust, placement, evidence — with pipeline and gate
metadata behind one `details`. Truncated text expands through `details` too:
native, keyboard-reachable, and script-free.

The clipboard is the one thing markup cannot do, so `Copy` is the console's only
LiveView hook. It lives in the same hand-written same-origin module that starts
the socket, which keeps `script-src 'self'` intact without a bundler or a policy
exception. Shortened identifiers are useless without a way to retrieve the whole
value, which is what earns the exception to an otherwise script-free surface.

## Graph rendering

The graph is deterministic server-side inline SVG because:

1. The browser pipeline's Content-Security-Policy allows `script-src 'self'`
   and forbids inline script, and the project has no bundler — the whole client
   build is one ES module that starts the LiveView socket. A drawing library
   would mean adding both a build step and a policy exception.
2. Node selection has to consult authorized data. A server round-trip lets the
   detail panel show what the reader may see without shipping the corpus to the
   browser.

Force simulation adds randomness or expensive pairwise iterations. The radial
layout is pure: containment-depth rings, statement orbits, and relation chords
produce the same testable picture for the same data.

Statement nodes are capped. When the cap drops rows the page says so; a partial
picture presented as complete is worse than no picture.

## What is deliberately absent

Gate-rule and retrieval-profile editing, peer and role administration, API key
issuance, connector administration, bulk export, and readiness checks for
another peer. The first four change behaviour or authority for everyone in a
scope and belong behind a reviewed path rather than a console form; bulk export
is the portability archive; and checking somebody else's readiness would
disclose which knowledge exists about them in scopes the reader may not hold.

## Evidence

- `test/cartulary_web/console/access_test.exs` — the visibility matrix and the
  action gates, including that a machine credential holds no console authority.
- `test/cartulary_web/console/graph_test.exs` — layout determinism, frame
  bounds, edge kinds, dropped dangling edges, and the absence of entity nodes.
- `test/cartulary_web/live/console_live_test.exs` — real sign-in, every page
  rendering against a seeded Account, an API key refused, a member denied the
  operations page, a scope the member holds no grant on absent rather than
  empty, the two explorer modes and their four empty states, the clamps on page
  size, sort, and page number, statement-page ordering, and a `back` value that
  cannot leave the explorer.
- `test/cartulary/f4_real_gate_a_b_governance_test.exs` and
  `test/cartulary/f9_skill_readiness_procedural_memory_test.exs` — unchanged,
  and still the contract for `/governance`.

## Related

- `specs/architecture/gate-a-b-governance.md` — the decisions the console
  dispatches.
- `specs/architecture/identity-tenancy-rbac.md` — the roles it reads.
- `specs/architecture/retrieval-entity-context.md` — the retrieval preview and
  the entity non-exposure rule.
- `docs/guides/web-console.md` — the user-facing guide.
