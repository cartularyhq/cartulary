<!-- SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0 -->

# Run from source

Source mode is for development. Supply PostgreSQL yourself.

## Prerequisites

- Elixir 1.17 or newer, with a matching Erlang/OTP.
- PostgreSQL with pgvector available, reachable at `localhost:5432`.

## Set up

```bash
cp .env.example .env
mix deps.get
mix ecto.migrate
```

`.env.example` lists every setting. Start with
`DATABASE_URL`, `CARTULARY_AUTH_SIGNING_SECRET`, and the model settings
described in [Configuration](../reference/configuration.md).

## Bootstrap the Account and first administrator

Use the idempotent bootstrap task to create the first administrator:

```bash
CARTULARY_BOOTSTRAP_PASSWORD='replace-with-a-long-password' \
  mix cartulary.identity.bootstrap \
    --email admin@example.test \
    --name 'Local Admin'
```

## Start the server

```bash
mix phx.server
```

The application is at `http://localhost:4000`.

## Working offline

Without a model provider, use the deterministic adapter for tests and smoke
runs:

```bash
CARTULARY_MODEL_LOCAL_FALLBACK=true
```

Production defaults it off and never falls back to it after a provider error.

## Running the checks

Run the standard checks:

```bash
mix deps.get
mix ash.codegen --check
mix format --check-formatted
mix compile --warnings-as-errors
mix test
```

Contribution rules, the full check matrix, and the review posture are in
[`CONTRIBUTING.md`](https://github.com/cartularyhq/cartulary/blob/main/CONTRIBUTING.md).

## Next

- [Quickstart tutorial](quickstart.md)
- [Mix tasks](../reference/mix-tasks.md)
