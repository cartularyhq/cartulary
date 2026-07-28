<!-- SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0 -->

# Run from source

Source mode is the development path. Unlike the packaged release, it downloads
no infrastructure at boot: you supply PostgreSQL yourself.

## Prerequisites

- Elixir 1.17 or newer, with a matching Erlang/OTP.
- PostgreSQL with pgvector available, reachable at `localhost:5432`.

## Set up

```bash
cp .env.example .env
mix deps.get
mix ecto.migrate
```

`.env.example` is the annotated, complete list of settings; copy it and edit
what you need. The variables that matter most on a first run are
`DATABASE_URL`, `CARTULARY_AUTH_SIGNING_SECRET`, and the model settings
described in [Configuration](../reference/configuration.md).

## Bootstrap the Account and first administrator

Cartulary needs one human identity before anything else can happen. This task
is idempotent and is the only supported way to create the first administrator.

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

If you have no model provider configured, an explicit deterministic local
adapter keeps tests and smoke runs working:

```bash
CARTULARY_MODEL_LOCAL_FALLBACK=true
```

It is a development and test aid only. Production defaults it off and will
never switch to it after a live provider fails — a silent downgrade from a real
model to a deterministic stand-in would corrupt memory quality invisibly.

## Running the checks

The standard gate, which every change must pass:

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
