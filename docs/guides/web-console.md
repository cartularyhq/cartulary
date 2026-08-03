<!-- SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0 -->

# Exploring memory in the web console

`/console` shows the memory your roles can reach, its provenance and history,
and the actions available to you.

```bash
open http://127.0.0.1:4000/sign-in
```

Readers, members, curators, and account admins may sign in. Roles change
visibility and available controls.

Agent API keys work on JSON and MCP, never the console.

## What you can reach

| Page | Shows |
| --- | --- |
| `/console` | Overview: totals, lifecycle and sensitivity mix, what is waiting, recent activity |
| `/console/knowledge` | The explorer: filter, page, and search every statement you can read |
| `/console/knowledge/<id>` | One statement in full, with its evidence, history, readable shared-entity neighbours, and available actions |
| `/console/scopes` | The containment tree as a directory, with counts, index coverage, your role, and lateral links |
| `/console/graph` | The same data drawn as a graph of scopes, statements, and cross-references |
| `/console/sources` | Documents, their versions, connectors, sessions, and raw observations |
| `/console/skills` | Skill requirement cards, and a live readiness check for yourself |
| `/console/tools` | A workbench for all eight MCP tools, using your signed-in identity and showing the returned payload |
| `/console/me` | Everything recorded about you, and your consent and erasure controls |
| `/console/operations` | Account admins only: readiness, usage and cost, entity-resolution quality, gate rules, retrieval tunings |
| `/governance` | Curators and account admins only: the gate queue and skill-card authoring |

Navigation hides inaccessible pages, but every destination independently
checks authority and refuses unauthorized requests.

## Trying the MCP tools in the browser

`/console/tools` provides one form for each tool exposed at `/mcp`. It calls
the same Ash actions as MCP, under your signed-in identity. Account and
calling-peer identity never come from a form.

The cards are grouped by what you are trying to do:

| Group | Cards | Action |
| --- | --- | --- |
| Retrieve | Ask memory, Search memory, Load context, Browse knowledge | `ask`, `search`, `get_context`, `query_knowledge` |
| Operate | Save observation, Resolve validation, Update question limits | `ingest`, `resolve_validation`, `set_ask_preference` |
| Evaluate | Check readiness | `check_readiness` |

Every card names its action under the submit button, so a payload you see here
maps to the tool an agent would call.

Retrieve and Evaluate are governed reads. The three Operate cards change
durable state, carry a marked edge, and ask you to acknowledge the consequence
before they submit: `ingest` persists and queues a raw observation,
`resolve_validation` answers one pending question addressed to you, and
`set_ask_preference` can only lower your own limits or extend a pause. The
workbench adds no curator, promotion, gate-administration, or bulk action.

## Session and scope on the workbench

**Run context** at the top of the page sets the session id and scope for every
card at once. The session id is generated when the page mounts; reuse it across
calls when you want inline validation delivery and later ingest to belong to
the same interaction, or press **Start a new session id** to begin a fresh one.

The scope box accepts any scope you can read and completes as you type, which
matters once an Account holds more paths than fit a list. A path you cannot
read is named as such before you submit, so a typo does not look like an empty
Account.

Each card keeps a collapsed **Context** section holding the same two fields.
Change them there to deviate for a single run without moving the page-wide
context.

## Reading a result

A completed call shows a short summary first — the answer, the counts, the
readiness verdict, the stored preference — followed by **What was submitted**
and the exact **Raw payload**. The summary is a reading aid; the payload is the
same value the underlying action returned, and stays available for debugging.

After `search` or `ask`, the browser adds `retrieval_health` for the selected
scope, and the summary reports its state. This browser-only object is not part
of the MCP or HTTP contract. It reports statement, embedding, and entity-mention
counts; embedding coverage; stored embedding identities; the configured query
identity; and one of `ready`, `missing_embeddings`, `missing_mentions`, or
`identity_mismatch`. When a derived index needs attention, `next_action` says to
rebuild the scope's derived data.

Up to five runs are kept under **Earlier runs** so you can compare a call with
the one before it. They live in the page only: a reload starts empty, and a
failed call leaves earlier results in place.

## What you see, and why you might see less than a colleague

Two rules narrow the console beyond the ordinary scope filtering.

**Provisional statements are visible only to their subject**, including against
account admins. Retrieval applies the same rule.

**Only curators and account admins see every state.** Members and readers see
`active`, `needs_revalidation`, `expired`, and `superseded`, but not
`proposed`, `held`, `rejected`, `contested`, or `redacted`.

**You always see statements about yourself**, regardless of state or scope, so
you can contest, redact, or erase them.

Two people looking at the same Account will therefore see different totals.
That is the scope tree working, not an inconsistency.

## Browsing versus retrieval

**Browsing** applies attribute filters — scope, state, kind, sensitivity,
subject — and pages through the result. It is exhaustive: what is not listed is
either filtered out or not visible to you, never merely ranked low.

**Retrieval** runs the same multi-strategy engine that answers an agent's
`search` call, and shows its working: which strategies contributed, which found
nothing, which were dropped against the deadline, and what each candidate
scored. It ranks; it does not enumerate.

Read the strategy tile before the results. A search where the strategies that
read your words all found nothing still returns a full page — of whatever is
most recent in the scope. It looks like an answer and is not one.

Retrieval requires a scope. Searching `/team/project` also searches `/team`
and `/`. A miss means nothing ranked, not that the exhaustive browser is empty.

## Index coverage

`/console/scopes` reports, per scope, how many of its statements carry an
embedding (**Indexed**) and how many entity mentions were resolved from them
(**Mentions**), plus the embedding model in use.

Statements are durable; those two are derived caches rebuilt in the background.
A scope can therefore hold every statement and answer nothing semantically —
word-based search keeps working, which is what makes the gap easy to miss. When
Indexed is lower than Statements the figure is highlighted, and semantic and
entity recall are degraded for that scope until its refresh runs again. Two
embedding models listed for one scope means part of it predates a model change
and must be re-embedded before those statements are comparable again.

Coverage counts only. Mentions is a number, never a list of names.

## The statement page

Everything the system holds about one claim is on `/console/knowledge/<id>`:

- the statement, its confidence, sensitivity, kind, and target level;
- **subject against source** — who the claim is about, and where it came from.
  A colleague can be the subject of something you said;
- **belief time against valid time** — when the system holds the claim, against
  when the claim is true in the world;
- the model, model version, and prompt version that extracted it, and the
  embedding identity attached to it;
- the raw observations and document versions it was extracted from, in full;
- its lifecycle timeline, and for curators the immutable gate decisions;
- its relations in both directions and the supersession chain it belongs to.
- the count and links for other statements that share a resolved entity and
  pass your scope and lifecycle visibility rules.

Unreadable cross-references are omitted. Missing and unauthorized statement ids
both return "not found".

## What you can change

Controls appear according to your authority. Everything below is carried out by
the governance layer, which records an immutable decision and a hash-chained
audit entry alongside the change.

### As a curator or account admin

On a statement with an open queue entry:

- **Approve** — the statement becomes `active` in its scope.
- **Reject** — it moves to `rejected` and is retained as evidence.
- **Defer** — the queue entry's due date moves out; the statement is untouched.
- **Edit as replacement** — this does *not* rewrite the statement. It mints a
  new statement carrying your wording, supersedes the original, and sends the
  replacement back through the gates. The original text stays readable.
- **Merge** — folds this statement's confidence, corroboration count, and
  sources into another statement, and supersedes this one.

You can also **request promotion** to a wider scope. Promotion does not move
anything by itself: the statement is held at the target scope for a second
human decision, and personal knowledge additionally waits for its subject's
consent.

The full queue, with bulk approve, reject, and defer, is at
[`/governance`](governance-console.md). Publishing skill requirement cards
happens there too.

### As the subject of a statement

On `/console/me`, or on any statement about you:

- **Confirm** — it becomes `active` at full confidence. First-hand confirmation
  by the subject is the strongest evidence available.
- **Contest** — it becomes `contested` and is queued for a curator within 24
  hours.
- **Redact** — it is withdrawn.

None of these is a curator power, and a curator cannot exercise them for you.

**Consent.** Personal knowledge being promoted to a wider scope waits for your
own consent, specific to that target scope. A grant is accepted only over a
channel that authenticated you — the browser session is one. A refusal is
recorded whatever the channel, because it must never be harder to refuse
exposure than to allow it.

**Erasure.** Proportionate erasure removes your content and scrubs shared
provenance. Strict erasure additionally removes knowledge that was only ever
sourced through you. Neither retracts knowledge that still has independent
provenance, and both retain content-safe audit evidence: the trace records that
something was removed, never what. Erasure runs immediately and cannot be
undone, which is why the control asks you to type `erase` first.

## The graph

`/console/graph` draws the same data as a picture. Distance from the centre is
depth in the containment tree, so the root sits in the middle. Each scope's
statements orbit it, so a dense scope looks dense. A statement's size is its
confidence and its colour is its lifecycle state.

Cross-ring lines are either **scope relations** between non-parent scopes or
**knowledge relations** between statements.

Select a node for details. Layout is deterministic. When too many statements
match, the page reports truncation instead of presenting a partial graph as
complete.

## What the console deliberately does not show

- **Resolved entities.** Entity and mention rows are a private recall cache
  whose rows span every scope that ever mentioned a name. Showing them would
  carry names across the boundary the scope tree exists to keep, so no
  canonical name, alias, surface form, or entity identifier appears anywhere in
  the console — including the graph. Account admins see only aggregate cache
  quality signals on the operations page. Statement detail may link readable
  statements that share an entity without naming that entity.
- **Embedding vectors and document chunks.** Rebuildable derived caches with no
  meaning to a reader. Chunk counts are shown; chunk contents are not.
- **Credentials.** Password hashes, API key hashes, and connector secrets are
  never rendered. Connectors show status, schedule, and error class only.

Console content never enters logs, telemetry, audit metadata, or job arguments.

## Appearance and offline use

The console uses your operating system's light or dark preference. It loads one
stylesheet and one small script, both served by this installation; there is no
content delivery network, no web font, and no image asset, so an air-gapped
deployment renders exactly the same page as any other.

## See also

- [Curating memory](governance-console.md) — the gate queue in depth
- [Acting on your own data](self-governance.md) — the same subject powers over HTTP
- [Isolation and access control](../concepts/security-model.md)
- [Search and ask](search-and-ask.md) — the retrieval engine the preview runs
