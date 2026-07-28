# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Repo do
  @moduledoc """
  The one database connection every part of Cartulary reads and writes through.

  There is exactly one repository, in every deployment mode. Whether the
  release supervises its own embedded PostgreSQL process or connects to a
  server an operator runs is an infrastructure choice made in configuration: it
  changes *where* Postgres lives, never how the product behaves. The same
  migrations, the same Ash actions, the same queues, and the same guarantees
  apply on both sides of that switch, so nothing in the codebase may branch on
  which one is in use.

  Durable writes belong in Ash actions, not here. Direct Ecto or raw SQL
  against this repository is confined to reviewed infrastructure helpers: the
  Account-scoped transaction helper, the read-only retrieval queries, the
  advisory lock helper, the credential bootstrap lookup, and the read-only
  readiness and usage-aggregation queries. None of them writes durable state.
  Anywhere else, reach for the resource's Ash action so tenancy filters,
  policies, audit entries, and job enqueues stay attached to the write.

  Connection settings come from configuration at boot. The custom Postgrex type
  module that teaches this connection the pgvector wire format is a
  compile-time setting, because Postgrex builds that module while compiling.

  `warn_on_missing_ash_functions?: false` suppresses the startup warning about
  the optional `ash-functions` SQL helper extension, which this schema does not
  install; without it every boot logs the same advisory.
  """

  use AshPostgres.Repo,
    otp_app: :cartulary,
    adapter: Ecto.Adapters.Postgres,
    warn_on_missing_ash_functions?: false

  @doc """
  The oldest PostgreSQL release this schema is supported on.

  AshPostgres asks for this to decide which server features it may emit rather
  than probing the live server — for example, whether a built-in UUID v7
  function exists. Declaring a version the deployment does not actually meet
  produces SQL the server rejects at runtime, so lower it only together with
  the migrations and queries that depend on the newer behaviour.

  The embedded database shipped with the no-container release is newer than
  this floor; the floor exists for operators running their own server.
  """
  def min_pg_version do
    %Version{major: 16, minor: 0, patch: 0}
  end

  @doc """
  PostgreSQL extensions the schema depends on, in the form AshPostgres expects.

  Generated migrations create these before anything that needs them:

  * `pgcrypto` — `digest()`, used by the migrations that backfill SHA-256
    content hashes.
  * `vector` — pgvector column and index support for embeddings.
  * `citext` — case-insensitive text, used for the peer login email column.

  Editing this list changes what the next generated migration installs, so it
  is a schema change: regenerate and review migrations rather than adding an
  entry to make a local query work.
  """
  def installed_extensions, do: ["pgcrypto", "vector", "citext"]
end
