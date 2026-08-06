<!-- SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0 -->

# Visible entity cards and projection oversight

## Status

Draft. Awaiting review.

Supersedes part of `specs/adr/0009-scope-bounded-entity-cards.md`. A new ADR
0011 must record the change before implementation starts.

## Problem

The console graph draws entity clusters as anonymous hubs. A hub shows
`Shared entity 6` and a list of member statements. The reader cannot tell what
the referent is.

Two further gaps follow from the same cause:

- A wrong entity merge is invisible. It corrupts retrieval expansion, and no
  surface shows it.
- Projections carry the freshness of every context read. No surface shows
  whether a card is dirty, stale, or still holding a retracted statement.

## Decisions

These are settled. The reasoning is in the sections below.

| Question | Decision |
| --- | --- |
| Entity label source | Scope-local `surface_form`, not `canonical_name` |
| Label and kind in `get_context` | Yes, additive, no `f7-1` bump |
| Card threshold | 2 sources for a card, 3 for a summary |
| Peer profile content | Account-admin only, on `/governance` |
| Console visibility rule | Unchanged. `/console/*` stays subject-only |

## Non-goals

- No reader-clearance axis. Reads stay scope-gated, as ADR 0009 decided.
- No entity permalink. `entity_id` stays a private cache coordinate, so no
  route may accept it.
- No card embedding and no card as a retrieval candidate. ADR 0009 defers
  both, and this design does not change that.
- No change to Gate A or Gate B. Cards are projections, never gated artifacts.

## Increment 1: entity cards carry an identity

### Label

`Cartulary.Context.Builder.build_entity_card_attrs!/5` computes a label for each
card. The label is the most frequent `EntityMention.surface_form` among the
mentions that produced the card, restricted to that card's own scope and its own
source statements. Ties break by longest form, then lexically, so the label is
deterministic across rebuilds.

The builder drops closed-class forms, so a pronoun cannot become a label. A
card whose forms are all closed-class carries no label and renders as an
ordinal, exactly as today.

Scope-local derivation is what makes this safe. `Entity.canonical_name` is
account-global and can carry a name coined in a scope the reader cannot see.
A scope-local surface form cannot: every character of it already appears in a
statement the same card supplies.

### Kind

The card also stores `Entity.kind`. It is a coarse resolution heuristic, and
any single source statement already implies it.

The pipeline actor reads `Entity` and `EntityMention` during the build. The
console reads neither. The projection stays the only channel, so the
pipeline-only read policy on both caches is unchanged.

### Thresholds

A card is built at two active sources. A summary is generated at three.

ADR 0009 set one threshold at three to bound model cost. That bound is
preserved: the summary is the only part that calls a provider, and it keeps the
original threshold. Label and kind cost one column read and one frequency
count.

A two-source card stores `summary: nil` and `summary_mode: "none"`. Consumers
of `get_context` must tolerate a null summary. This goes in the changelog.

### Payload

`label`, `kind`, and the widened `summary_mode` are additive members of the
existing `entity_cards` content. ADR 0009 established that additive members
leave `f7-1` unchanged. A changelog entry is still required.

### Console graph

`Cartulary.Retrieval.Store.shared_entity_clusters/3` also returns the
`entity_id` for each cluster. The value stays inside the loader.

`CartularyWeb.Console.Loader` reads clean `entity_card` projections for the
drawn scopes and attaches each card to its cluster. The read needs no new
policy: `Cartulary.Knowledge.Projection` already authorizes reads through
`Cartulary.Policy.ScopeAccess` on `scope_id`.

The cluster panel shows the label, a kind badge, a sensitivity badge, the
summary with its `summary_mode`, and then the member statements. Hub labels use
the focus-scope label when one exists and the ordinal otherwise.

Cards exclude provisional statements, but the drawn statement set includes the
viewer's own provisional statements. A cluster can therefore hold members the
card does not cover. The panel lists card sources and cluster members as two
separate groups, so the summary never appears to cover a statement it did not
read.

Derived content and governed content must stay visually distinct. A card
summary is model output. A statement is governed knowledge.

## Increment 2: entities as graph nodes

`shared_entity_clusters` gains a minimum-mention parameter. At one mention every
entity in view becomes a node. The graph page carries a toggle, in the same
shape as the existing `descendants` control, and a node cap that reports
truncation the way the statement limit already does.

Co-mention edges join two entities named in the same statement. One join over
`entity_mentions` produces them. Both endpoints come from a single readable
statement, which satisfies the rule that expansion requires access to both
relation endpoints.

A co-mention edge means "named together", not "related to". The legend must say
so. Cartulary has no entity-relation table, and this edge does not create one.

## Increment 3: projection oversight

A new page at `/governance/projections` lists projections for a chosen scope.

This is the first console surface that reads `Knowledge.Projection` directly
rather than through `Cartulary.Context`. That is a new boundary and needs its
own ADR.

### What each role sees

| Kind | Metadata | Content |
| --- | --- | --- |
| `scope_card` | Curator, admin | Curator, admin |
| `session_summary` | Curator, admin | Curator, admin |
| `entity_card` | Curator, admin | Curator, admin |
| `peer_profile` | Curator, admin | Account-admin only |

Metadata is `kind`, `version`, `dirty`, `watermark`, `delta_count`, source
count, and the resolved scope, peer, or session. It carries no statement text.

The `/governance` session admits curators and account-admins, so the route gate
is not sufficient. The page must check for account-admin before it renders
peer-profile content.

### Why peer profiles are the exception

`Knowledge.Projection` authorizes reads on `scope_id` alone. It does not filter
by peer. What keeps one peer's profile away from another today is the access
pattern in `Cartulary.Context`, which builds the peer cache key from
`actor.peer_id` and never from a request parameter.

A list that enumerates projections by scope bypasses that guard. Peer profiles
are also the only projection kind that stores provisional content, because
shared scope and session content is active-only.

Placing the page on `/governance` keeps this coherent. `/console/*` remains
subject-only for every role, and `CartularyWeb.Console.Access.visible_knowledge?`
does not change. Oversight lives on a separate, role-gated surface.

An account-admin who reads another peer's provisional content emits a
content-safe audit record: actor, subject peer id, scope, and time. No
statement text.

`source_ids` on any card can name statements the viewer cannot read. The page
renders counts, and links only through the already-authorized loaded set. This
is the rule `cluster_members/2` already applies on the graph.

## Increment 4: scoped entity list

A page listing one scope's entity cards, ordered by source count. It reuses
increment 1's data and increment 3's access rules, and adds no new read path.

It is where systematic merge errors become visible. The graph only shows
clusters among the drawn statement limit, so the graph alone cannot show them.

Members link to `/console/knowledge/:id`. There is no per-entity route, because
the URL cannot carry `entity_id`.

## Contract impact

| Artifact | Change |
| --- | --- |
| ADR 0009 | Superseded in part by ADR 0011: surface forms may appear in a scope card drawn from that card's own readable sources |
| New ADR | Console surfaces may read `Knowledge.Projection` directly |
| `AGENTS.md` | Retrieval section: the surface-form prohibition gains the scope-card exception |
| `AGENTS.md` | Browser console section: `/governance` may show peer-profile content to account-admins |
| `f7-1` | Unchanged. Additive members only |
| `CHANGELOG.md` | Label, kind, nullable summary, new pages |
| `docs/concepts/retrieval.md` | Entity anonymity claim is now scope-bounded, not absolute |
| Console guide, HTTP route table | New routes and controls |

## Risks

**Label quality.** `surface_form` is raw extracted text. Frequency-max and the
closed-class filter help. Some labels will still read badly, and no tuning
fixes a bad extraction. A poor label is still more informative than an ordinal.

**Label flicker.** A card goes dirty on any lifecycle change in its scope and
stays dirty until the refresh job runs. A curator approving statements sees
labels fall back to ordinals. The panel must show a refreshing state rather
than fail silently.

**Derived content read as governed.** A model-written summary beside governed
statements invites the reader to cite it. Visual separation and the
`summary_mode` badge are the mitigation.

**Widened admin reach.** Increment 3 lets an account-admin read another peer's
provisional content. The route boundary, the in-page role check, and the audit
record are the mitigations. Curators gain nothing.

## Evidence

| Test | Covers |
| --- | --- |
| `test/cartulary/context/builder_test.exs` | Label determinism; a label never draws on a statement outside the card's sources; closed-class rejection; both thresholds |
| `test/cartulary/f7_retrieval_entity_context_test.exs` | Additive payload members; null summary at two sources |
| `test/cartulary_web/console/graph_test.exs` | Hub labels; ordinal fallback; card and cluster member separation |
| `test/cartulary_web/live/console_live_test.exs` | Panel rendering; truncation reporting |
| `test/cartulary_web/console/access_test.exs` | `/console/*` provisional rule unchanged |
| New governance page test | Curator sees peer-profile metadata and not content; admin sees content; the read is audited |

## Delivery

Four pull requests, in order. Increments 3 and 4 depend on 1. Increment 2 is
independent of 3 and 4.

Increment 1 ships first on its own. It will show whether surface-form labels
are good enough to justify building three more surfaces on them.
