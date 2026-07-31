<!-- SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0 -->

# Install a packaged release

The packaged release includes and supervises a checksum-pinned pg0 PostgreSQL
distribution with pgvector.

## Run it

Unpack the release built for your operating system and architecture, then:

=== "macOS / Linux"

    ```bash
    bin/server
    ```

=== "Windows"

    ```powershell
    bin\server.bat
    ```

On first start the launcher:

1. creates a private data root at `~/.cartulary`;
2. generates the local signing secret;
3. starts the packaged pg0 binary and creates its PostgreSQL cluster;
4. runs every migration against the fresh database;
5. starts Phoenix on port 4000.

Confirm it is up:

```bash
curl -fsS http://127.0.0.1:4000/api/ready
```

A 200 means the database, job queues, and model roles are ready. A 503 names
failing components with content-safe counts, versions, and error classes.

!!! warning "It fails closed, on purpose"
    If the port is occupied, or the data directory and configuration are
    unhealthy, the release refuses to accept traffic rather than starting in a
    half-working state.

## Change the defaults

Set these **before the first start**; they decide where durable state is
created:

| Variable | Default | Meaning |
| --- | --- | --- |
| `CARTULARY_DATA_ROOT` | `~/.cartulary` | Private data root for database, blobs, and secrets |
| `PORT` | `4000` | HTTP port |
| `CARTULARY_PG0_PORT` | `5432` | Port the supervised PostgreSQL listens on |

The complete list is in [Configuration](../reference/configuration.md).

## Point it at your own PostgreSQL instead

The same release can use operator-run PostgreSQL 18 with pgvector:

```bash
export CARTULARY_DATABASE_MODE=external
export DATABASE_URL='ecto://user:password@db.example/cartulary'
export CARTULARY_AUTO_MIGRATE=true
export CARTULARY_AUTH_SIGNING_SECRET='at-least-64-random-bytes...'
export CARTULARY_BLOB_ROOT=/absolute/durable/blob/path
bin/cartulary start
```

Set `CARTULARY_AUTO_MIGRATE=false` when change control requires migrations to
be a separate step, then run `bin/migrate` before starting the release.

## Build a release from source

Both scripts download the exact pg0 asset named in `rel/pg0/VERSION`, verify it
against `rel/pg0/checksums.txt`, and stage it only for release assembly:

=== "macOS / Linux"

    ```bash
    ./scripts/package-release
    ```

=== "Windows"

    ```powershell
    scripts\package-release.ps1
    ```

## Next

- [Quickstart tutorial](quickstart.md) — bootstrap an administrator and record
  your first observation.
- [Operations overview](../operations/index.md) — upgrades, backups, and
  running this in earnest.
