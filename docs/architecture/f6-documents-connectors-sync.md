<!-- SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0 -->

# F6 Documents, Connectors, And Sync

Status: implemented

F6 makes documents a first-class free-core observation path. It implements
`FR-TOP-10`, `FR-KN-5`, `FR-FORM-9` through `FR-FORM-12`,
`FR-FORM-14`, `FR-FORM-17`, `AD-SEAM-1` through `AD-SEAM-4`,
`AD-DATA-5`, `AD-PIPE-1` through `AD-PIPE-4`, `AD-PORT-1`, `AINV-5`,
and the document-outage portion of `NFR-8`.

## Durable and derived boundaries

F6 takes the configured boundary to ten Ash Domains and 38 Resources.
`Cartulary.Observations.Document` identifies one logical source document and
its scope. `DocumentVersion` is immutable source history carrying:

- SHA-256 content hash and byte count;
- media type and content-bearing source metadata;
- a durable blob reference;
- source occurrence time; and
- content-safe processing state and counts.

The local free-core adapter stores immutable bytes under
`account/content-hash`; the S3-compatible adapter uses ExAws and the same
reference contract. Adapter choice is runtime infrastructure configuration.
It does not change hashes, version behavior, gates, or sync semantics. A
deterministic content-addressed put may leave a harmless orphan when the later
database transaction rolls back; it can never replace a different object and
is eligible for later reconciliation.

`Cartulary.Documents.ConnectorConfig` is durable authored state: scope, owner,
adapter kind, interval schedule, cursor, next/last sync timestamps, status,
content-safe config, and an optional secret reference. Raw credentials are
rejected. `DocumentChunk` is a rebuildable derived cache: version and byte
range, chunk hash, text, vector, and pinned embedding identity. Chunks and
vectors are excluded from logical export and regenerated from version blobs.

The F6 migration preserves PostgreSQL RLS on both new Account-scoped tables,
adds foreign keys and scheduling/lookup indexes, retains the existing
document-version FTS column, and safely represents any pre-F6 inline document
content with a `legacy-db://` reference. F7 converts chunk embeddings from
float arrays to PostgreSQL `vector`, adds the chunk HNSW and generated-FTS
indexes, and retrieves chunks through Semantic and Lexical strategies.

## Dual ingest

`Cartulary.Documents.ingest_bytes/2` writes the content-addressed blob, creates
or reuses the scoped logical document, appends a new immutable version only
when the hash changed, and uses the existing F2 Ash change to commit:

1. the raw `DocumentVersion`;
2. a content-safe hash-chain audit event;
3. a deterministic `PipelineRun`; and
4. its AshOban extraction job.

The ingest job reads bytes through the blob port. Markdown is parsed through
MDEx into a validated AST and normalized Markdown. PDF, Office, email, HTML,
and the other supported binary formats use the native ExtractousEx NIF; plain
UTF-8 text uses the direct no-loss path.

TextChunker supplies format-aware chunks and byte offsets. The bitcrowd/rag
embedding stage attaches vectors produced by the pinned F5 `embedder` role.
Every chunk records provider, model, version, and dimensions. The same parsed
text then enters the F5 structured extractor. Subject remains distinct from
the document source, provenance links the resulting item to
`document_version_id`, and every new item enters the unchanged F4 Gate A/B
lifecycle. Agents and connectors therefore submit raw observations only.

Processing records counts, parser name, byte size, and IDs in telemetry. It
never copies bytes, extracted text, statements, source metadata, cursors, or
secrets into spans, audit metadata, or Oban arguments. Provider/parser failure
leaves the raw version, blob, audit, and retryable job durable.

## Incremental sync and history

Connector adapters implement one `pull(config, cursor)` callback and return a
page of raw items plus the next cursor. The cursor advances only after every
item is durably versioned, recognized as an unchanged hash, or tombstoned.
Schedules use a durable next-sync timestamp and deterministic
connector/cursor/scheduled-time job identity. The Account reconciler also
re-enqueues due connectors and pending/failed document versions.

For a changed source, unchanged extracted statements merge the new provenance
into the existing knowledge item. Prior-version statements not reproduced by
the new version transition to `superseded`, retain their statement, provenance,
lifecycle, and audit history, and receive a `supersedes` relation when a new
replacement exists. Prior chunks are marked superseded. A remote deletion
tombstones the document and its chunks. Knowledge supported only by that
document is retracted without deleting history; items with independent
provenance remain governed and retrievable.

## Erasure and portability

`Cartulary.Documents.Portability` is the document component of the F10
account-wide archive. Its `f6-document-1` bundle carries durable document and
version metadata plus checksum-verified blob bytes. It explicitly excludes
chunks and embeddings; import passes every raw version through ordinary ingest
and enqueue, so derived data is rebuilt under the target embedder identity.
F10 still owns the complete transaction-consistent Account archive, JSONL
layout, audit-chain verification, and operator-facing commands.

Document erasure removes derived chunks, document/version metadata, exclusive
blob objects, and document provenance. Knowledge supported only by the erased
document is removed through the F4 erasure helper; knowledge with surviving
provenance remains. Content-addressed blobs shared by another version are not
deleted. Audit retains only IDs, hashes, actions, and counts.

## Evidence and version posture

- Document, connector, chunk, blob, parser, sync, and portability code:
  `lib/cartulary/documents/`
- Ash domain/resources: `lib/cartulary/documents.ex` and
  `lib/cartulary/observations.ex`
- Pipeline integration: `lib/cartulary/pipeline/`
- Resource migration:
  `priv/repo/migrations/20260728082728_f6_documents_connectors_sync.exs`
- Generated snapshots: `priv/resource_snapshots/repo/`
- F6 acceptance suite:
  `test/cartulary/f6_documents_connectors_sync_test.exs`

F0 HTTP response shapes, the F4 lifecycle contract, and F5 message extraction
remain unchanged. F6 adds a new document path and does not rename the existing
`f5-1` health/message pipeline identity. F7 subsequently advances retrieval
profile identity to `f7-1`.
