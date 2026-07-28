<!-- SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0 -->

# Exploring memory in the web console

The console at `/console` is the browser surface for people. It shows every
statement your roles reach, where each one came from, how it reached its
current state, and what you are allowed to do about it.

```bash
open http://127.0.0.1:4000/sign-in
```

Any human role can sign in — reader, member, curator, or account admin.
Reading the memory your grants reach is not a privileged act. What differs
between roles is what the pages show and which controls appear.

An agent API key cannot open the console. It is a valid credential on the JSON
and MCP surfaces, but the console offers gestures only a person may take on
their own behalf, so a machine credential is turned away exactly like no
credential at all.

## What you can reach

| Page | Shows |
| --- | --- |
| `/console` | Overview: totals, lifecycle and sensitivity mix, what is waiting, recent activity |
| `/console/knowledge` | The explorer: filter, page, and search every statement you can read |
| `/console/knowledge/<id>` | One statement in full, with its evidence, history, and the actions open to you |
| `/console/scopes` | The containment tree as a directory, with counts, your role, and lateral links |
| `/console/graph` | The same data drawn as a graph of scopes, statements, and cross-references |
| `/console/sources` | Documents, their versions, connectors, sessions, and raw observations |
| `/console/skills` | Skill requirement cards, and a live readiness check for yourself |
| `/console/me` | Everything recorded about you, and your consent and erasure controls |
| `/console/operations` | Account admins only: readiness, usage and cost, gate rules, retrieval tunings |
| `/governance` | Curators and account admins only: the gate queue and skill-card authoring |

Navigation hides what you cannot reach. Hiding a link is a convenience, not a
control — every destination re-checks your authority when it is opened, and a
request for a page you may not see is declined rather than served empty.

## What you see, and why you might see less than a colleague

Two rules narrow the console beyond the ordinary scope filtering.

**Provisional statements are visible only to their subject.** A statement in
the `provisional` state is one peer's working knowledge while a decision is
pending. It is hidden from everyone else, including account admins. This is the
same rule retrieval applies, so the console and an agent's `search` agree about
what exists.

**Undecided and withdrawn states are for curators.** A member or reader sees
`active`, `needs_revalidation`, `expired`, and `superseded` — the states that
represent settled belief. They do not see `proposed`, `held`, `rejected`,
`contested`, or `redacted` statements, because those have either not cleared a
gate or been withdrawn on purpose. Curators and account admins see all of them,
because deciding what happens to them is their work.

**Except about yourself.** Any statement whose subject is you is visible to you
whatever its state and whichever scope it lives in — even a scope you hold no
role on. That exemption is what makes contesting, redacting, and erasure real
rather than theoretical.

Two people looking at the same Account will therefore see different totals.
That is the scope tree working, not an inconsistency.

## Browsing versus retrieval

The explorer offers both, side by side, and they answer different questions.

**Browsing** applies attribute filters — scope, state, kind, sensitivity,
subject — and pages through the result. It is exhaustive: what is not listed is
either filtered out or not visible to you, never merely ranked low.

**Retrieval** runs the same multi-strategy engine that answers an agent's
`search` call, and shows its working: which strategies contributed, which were
dropped against the deadline, and what each candidate scored. It ranks; it does
not enumerate.

Retrieval needs a scope to search from, because context flows down the
containment tree — searching at `/team/project` also searches `/team` and the
root. Pick a scope in the filter bar and the search box becomes active. A
retrieval miss is a ranking result, not proof that the memory is empty; the
list below it is the exhaustive one.

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

A cross-reference to a statement you cannot read is omitted entirely rather
than shown as a dead identifier, because the presence of the link would itself
disclose that the hidden statement exists. An identifier that names nothing and
one you are not entitled to see report the same "not found".

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

Two kinds of line cross the rings rather than following them, and those are the
interesting ones: a **scope relation** links scopes that are not in a
parent-child line, and a **knowledge relation** links two statements.
Containment is predictable; cross-references are not.

Select any node to see what it is and jump to its full record. The layout is
deterministic — the same data always draws the same picture, so you can come
back and find things where you left them. When more statements match than can
be drawn legibly, the page says so rather than presenting a partial picture as
a complete one.

## What the console deliberately does not show

- **Resolved entities.** Entity and mention rows are a private recall cache
  whose rows span every scope that ever mentioned a name. Showing them would
  carry names across the boundary the scope tree exists to keep, so no
  canonical name, alias, surface form, or entity identifier appears anywhere in
  the console — including the graph.
- **Embedding vectors and document chunks.** Rebuildable derived caches with no
  meaning to a reader. Chunk counts are shown; chunk contents are not.
- **Credentials.** Password hashes, API key hashes, and connector secrets are
  never rendered. Connectors show status, schedule, and error class only.

Text you read in the console — statements, observations, document titles — is
for the browser. It is never copied into logs, telemetry, audit metadata, or
background-job arguments.

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
