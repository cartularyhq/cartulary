# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Portability do
  @moduledoc """
  The public entry point for moving a whole Account between installations.

  Portability is what makes "you own your data" concrete: an operator can lift
  an entire Account out of one deployment as a single file and restore it into
  another, with no proprietary service in the path. This module is the boundary
  callers (operator tasks and tooling) should use; the archive format and its
  verification live behind it.

  Three operations: write an archive, check one without touching the database,
  and restore one.

  What travels and what does not:

  - **Travels:** the Account and its scopes, peers, sessions, raw observations,
    documents and their immutable version history, governed knowledge with its
    provenance, attributions, lifecycle history and governance decisions, usage
    events, pipeline run identities, and the complete audit chain — plus the
    original document blobs, each verified against its checksum.
  - **Never travels:** credentials, password hashes, and secret values, because
    an archive is a file that gets copied around; and vectors, document chunks,
    projections, entities, and entity mentions, because those are rebuildable
    caches that would only be stale copies of something the target can recompute.

  Restoring is not a merge. An import must target a fresh Account and is
  rejected outright if one already exists, so an archive can never silently
  overwrite or interleave with live data. Before anything durable is written the
  entire archive is verified — schema, per-file checksums, row counts, blob
  hashes, and the full audit chain — so a tampered or truncated archive fails
  before it can be half-applied.
  """

  @doc """
  Writes a complete logical archive for the actor's Account to `output_path`.

  Reads in one Account-scoped transaction, so the archive is a coherent
  snapshot. Returns `{:ok, summary}` describing the written path, the archive
  schema, resource counts, blob count, verified audit head, and duration.
  Raises on an unreadable blob, a blob whose bytes no longer match their
  recorded checksum, or a filesystem failure.
  """
  defdelegate export(actor, output_path), to: Cartulary.Portability.Archive

  @doc """
  Restores an archive into a fresh Account.

  Verifies the whole archive first, stores its blobs, then — in one
  Account-scoped transaction — performs every durable write and queues the
  derived-cache rebuilds the archive deliberately omits. Returns `{:ok, summary}`
  with per-resource counts, blob count, the manifest hash, and the audit head.

  Raises if the target Account already exists, if any verification step fails,
  or if the restore transaction cannot commit — in which case nothing durable
  from the archive remains.
  """
  defdelegate import(input_path), to: Cartulary.Portability.Archive

  @doc """
  Verifies an archive without writing anything.

  Runs exactly the checks an import runs before its transaction — schema,
  checksums, counts, blob hashes, and the audit chain — and reports the schema,
  Account id, manifest hash, and audit head. Raises with the specific failure if
  the archive is not sound.
  """
  defdelegate validate(input_path), to: Cartulary.Portability.Archive
end
