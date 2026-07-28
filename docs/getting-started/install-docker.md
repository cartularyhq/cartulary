<!-- SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0 -->

# Run with Docker

The container path runs the same release against a stock PostgreSQL image. The
supervised pg0 binary is deliberately **not** in the container — a container
host already has a supported way to run a database, and shipping a second one
inside the image would fork the operational story for no benefit.

## Start the stack

```bash
docker compose up --build
```

The application is then at `http://127.0.0.1:4000`:

```bash
curl -fsS http://127.0.0.1:4000/api/ready
```

The image runs as a non-root user.

## With local tracing and metrics

```bash
CARTULARY_OTEL_ENABLED=true docker compose --profile observability up --build
```

This adds the local collector stack. See
[Observability](../operations/observability.md) for what it exports and what it
is forbidden from recording.

!!! danger "Replace the development credentials before exposing this"
    The Compose file ships a signing secret and a database password suitable
    only for a developer machine. Replace both before this stack is reachable
    by anything other than your own workstation.

## Configuration

Everything is environment-driven; the Compose file simply passes variables
through. See [Configuration](../reference/configuration.md) for the full set,
and in particular:

- `CARTULARY_AUTH_SIGNING_SECRET` — at least 64 random bytes, independent of
  `SECRET_KEY_BASE`;
- `DATABASE_URL` — the container path always uses external-database mode;
- `CARTULARY_BLOB_ROOT` — must be a durable volume if you ingest documents,
  because the database stores content hashes and blob references rather than
  the bytes themselves.

## Next

- [Quickstart tutorial](quickstart.md)
- [Operations overview](../operations/index.md)
