<!-- SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0 -->

# Browser Console

Status: implemented

The browser console is the human-facing read and self-governance surface. It
turns the durable model — scopes, statements, provenance, lifecycle, consent —
into something a person can inspect and act on without an HTTP client, and it
does so without introducing a second writer, a second authorization model, or a
second definition of what is visible.

It implements the human-surface obligations of `FR-UI-1` through `FR-UI-4`,
`FR-KN-9`, `FR-KN-14`, `FR-GOV-3`, `FR-GOV-8`, `AD-SEAM-2`, `AINV-2`,
`AINV-4`, `AINV-7`, `AINV-8`, and `NFR-9`, and it is bound by the entity-cache
non-exposure rule of `AINV-6`.

## Why a second browser surface was not created

Before this change the only browser page was the curator queue at
`/governance`, behind a mount hook that admitted the `curator` and
`account-admin` roles. Two designs were possible: a separate application for
reading, or one console with the queue inside it.

One console was chosen. The deciding argument is that a decision and the
evidence for it belong on the same page: a curator judging a proposal needs its
provenance, its lifecycle, its conflicts, and the raw observation behind it,
and a separate reading application would have meant either duplicating those
panels or asking a curator to hold two tabs open.

`/governance` therefore stayed exactly where it was, kept its own stricter
mount hook, and gained the shared console frame. Its route, its module name,
its event names, and its rendered heading are unchanged, because
`test/cartulary/f4_real_gate_a_b_governance_test.exs` and
`test/cartulary/f9_skill_readiness_procedural_memory_test.exs` assert on all
four. The console's per-statement page offers the same decisions through the
same operation-layer calls; the queue remains the place for working a backlog,
including the bulk actions that only make sense there.

## Layering

| Module | Owns |
| --- | --- |
| `CartularyWeb.ConsoleAuth` | Mount-time authentication: valid session token, password identity kind. No role check. |
| `CartularyWeb.GovernanceAuth` | The same, narrowed to `curator` and `account-admin`. Unchanged. |
| `CartularyWeb.SessionController` | `/sign-in` for any human role; `/sign-out`; the bare-origin redirect. |
| `CartularyWeb.Console.Access` | The two visibility rules and the action gates. Pure. |
| `CartularyWeb.Console.Loader` | Every database read the console performs. |
| `CartularyWeb.Console.Graph` | Deterministic radial layout. Pure. |
| `CartularyWeb.ConsoleComponents` | Shell, navigation, tiles, badges, tables, panels. Stateless. |
| `CartularyWeb.ConsoleLive.*` | Nine pages: rendering and event dispatch only. |

Both browser surfaces read the session key `governance_token`. The name is
historical and is deliberately not renamed: two keys would mean a curator
signing in at one door found the other locked, and renaming it would invalidate
every live session for no behavioural gain.

## Visibility

Ash policies and row-level security decide Account and scope before the console
is consulted. Two further rules are lifecycle-shaped, which policies cannot
express, and both live in `Access` so that no page can widen them
independently. Both are narrowing; neither can grant access to a scope the
actor's grants do not already reach.

**The provisional rule.** `state != "provisional" or subject_peer_id ==
<viewer>`. This is character-for-character the condition
`Cartulary.Retrieval.Store` applies to every candidate query. If the console and
retrieval ever disagree about provisional visibility, one of them is leaking;
they are intentionally the same expression so a reviewer can compare them.

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

The console performs none. Each gesture forwards to an existing operation:

| Gesture | Operation |
| --- | --- |
| Approve, reject, defer, edit-as-replacement, merge | `Governance.Engine.decide/4` |
| Bulk decisions (queue only) | `Governance.Engine.bulk_decide/4` |
| Promotion request | `Governance.Engine.request_promotion/3` |
| Confirm, contest, redact | `Governance.Engine.contest/3` |
| Consent grant or deny | `Governance.Engine.subject_consent/6` |
| Erasure | `Governance.Erasure.request/3` |
| Skill card publication (queue only) | `Skills.publish/2` |

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

Text rendered here does not travel: nothing in the console writes a statement,
an observation, or a document title into a log, a telemetry attribute, an audit
entry, or a job argument.

## Graph rendering

The graph is laid out server-side and emitted as inline SVG. Two constraints
forced that and would force it again:

1. The browser pipeline's Content-Security-Policy allows `script-src 'self'`
   and forbids inline script, and the project has no bundler — the whole client
   build is one ES module that starts the LiveView socket. A drawing library
   would mean adding both a build step and a policy exception.
2. Node selection has to consult authorized data. A server round-trip lets the
   detail panel show what the reader may see without shipping the corpus to the
   browser.

A force simulation was rejected because it needs either randomness or many
pairwise iterations: the first makes the picture jump on every render, the
second makes a page load slow on a large Account, and both would put a
non-deterministic function on a page a reader uses for navigation. The radial
layout is a pure function of its input — scopes on concentric rings by
containment depth, statements in orbits around their scope, cross-references as
chords — so the same data always draws the same picture and the layout can be
asserted on directly.

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
  operations page, and a scope the member holds no grant on absent rather than
  empty.
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
