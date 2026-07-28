# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0
#
# Production container image for Cartulary.
#
# Purpose
#   Build the same Mix release the no-container package ships, and run it in a minimal
#   Debian layer that contains no build tools, no Rust, and no database.
#
# Inputs
#   Build context: the repository root. Build arguments ELIXIR_IMAGE, DEBIAN_IMAGE, and
#   RUST_IMAGE pin the three base images; they are overridable but every supported build
#   uses the pinned defaults. No secrets are consumed at build time.
#   Runtime: environment variables read when the release boots. DATABASE_URL and
#   CARTULARY_AUTH_SIGNING_SECRET are mandatory; the container will refuse to start
#   without them rather than invent a default.
#
# Outputs
#   A single image whose entry point is the release launcher, listening on port 4000 and
#   running as an unprivileged user.
#
# Assumptions
#   A PostgreSQL with the pgvector extension is reachable at DATABASE_URL. This image
#   deliberately contains no embedded database: only the unpacked no-container release
#   ships one. Putting both in a container would mean two PostgreSQL servers competing
#   for the same data volume.
#
# Base images are pinned by exact tag, including the Debian snapshot date, so a rebuild
# of an old commit produces the same runtime rather than whatever "bookworm-slim" points
# at today. The Elixir and Debian tags must stay on the same Debian release: the release
# is compiled against the build image's C library and will not start on a different one.

ARG ELIXIR_IMAGE=hexpm/elixir:1.18.4-erlang-27.3.4-debian-bookworm-20250428-slim
ARG DEBIAN_IMAGE=debian:bookworm-20250428-slim
ARG RUST_IMAGE=rust:1.85-slim-bookworm

# Rust is needed only to compile the native extensions behind document text extraction,
# the local ONNX embedding runtime, and the tokenizer, when no precompiled artifact is
# available for this platform. It is pulled in as its own stage and copied into the build
# stage so the toolchain version is pinned independently of the Elixir image.
FROM ${RUST_IMAGE} AS rust-toolchain

FROM ${ELIXIR_IMAGE} AS build

COPY --from=rust-toolchain /usr/local/cargo /usr/local/cargo
COPY --from=rust-toolchain /usr/local/rustup /usr/local/rustup

# Build-only packages. They stay in this stage and never reach the runtime image.
RUN apt-get -o Acquire::Retries=5 update \
    && apt-get -o Acquire::Retries=5 install -y --no-install-recommends build-essential git curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
# Production build: this is what selects the release configuration and excludes the
# development and test tooling from the artifact.
ENV MIX_ENV=prod
# Generous network settings for the package and crate downloads. Image builds run on
# shared, frequently rate-limited runners, and a truncated dependency fetch surfaces much
# later as a confusing compile error. The Hex and Cargo timeouts are in seconds;
# concurrency 1 trades build speed for not tripping rate limits.
ENV MIX_HTTP_TIMEOUT=120000
ENV HEX_HTTP_TIMEOUT=120
ENV HEX_HTTP_CONCURRENCY=1
ENV CARGO_HOME=/usr/local/cargo
ENV RUSTUP_HOME=/usr/local/rustup
ENV PATH=/usr/local/cargo/bin:${PATH}
ENV CARGO_HTTP_TIMEOUT=120
ENV CARGO_NET_RETRY=5

# Installing the Hex and rebar archives is a network call with no built-in retry, and it
# is the very first thing a build does. Each is attempted up to three times so one flaky
# connection does not fail an otherwise good build.
RUN (mix local.hex --force \
      || mix local.hex --force \
      || mix local.hex --force) \
    && (mix local.rebar --force \
      || mix local.rebar --force \
      || mix local.rebar --force)
# Dependency manifests are copied on their own, before any source, so the expensive fetch
# and compile below is cached and only re-runs when the manifests themselves change.
COPY mix.exs mix.lock ./
# The cache mounts hold downloaded precompiled native artifacts and the Cargo registry.
# They make repeat builds tolerable; they are mounts rather than layers, so nothing from
# them is baked into the image.
RUN --mount=type=cache,target=/root/.cache/rustler_precompiled \
    --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    mix deps.get --only prod && mix deps.compile

# Application sources, copied after dependencies so an ordinary code change reuses the
# dependency layers. `rel` is required: it carries the overlay files that become the
# release's extra launchers.
COPY config config
COPY lib lib
COPY priv priv
COPY rel rel
RUN mix compile && mix release

# Runtime stage. Starts from plain Debian, not from the Elixir image: the release bundles
# its own Erlang runtime, so nothing from the build stage is needed except the release
# directory itself. That keeps compilers, Rust, and the package cache out of production.
FROM ${DEBIAN_IMAGE} AS runtime

# The minimum shared libraries a compiled BEAM release needs, plus curl for the health
# check below. Adding anything else here widens the attack surface of the shipped image.
# The service account is unprivileged and has a fixed high uid so a host bind-mount can be
# given matching ownership; the blob directory is created and handed to it up front,
# because the running process must not need permission to create its own storage root.
RUN apt-get -o Acquire::Retries=5 update \
    && apt-get -o Acquire::Retries=5 install -y --no-install-recommends libstdc++6 openssl libncurses6 curl ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --create-home --uid 10001 cartulary \
    && mkdir -p /var/lib/cartulary/blobs \
    && chown -R cartulary:cartulary /var/lib/cartulary

WORKDIR /app
COPY --from=build --chown=cartulary:cartulary /build/_build/prod/rel/cartulary ./

# Everything from here runs unprivileged. HOME must be set because the Erlang runtime
# writes cookie and cache files into it.
USER cartulary
ENV HOME=/home/cartulary
# Start the web endpoint. Without this the release boots the application but serves
# nothing, which is the correct behaviour for a one-off command invocation.
ENV PHX_SERVER=true
# The container always talks to a PostgreSQL somebody else runs. This is not a fallback:
# the embedded-database mode is not available in this image.
ENV CARTULARY_DATABASE_MODE=external
# Migrations are not applied on boot here. A container is commonly scaled to several
# replicas, and several replicas racing to migrate the same database is exactly the
# situation to avoid; schema changes are also an operator decision that wants a rollback
# plan. Run the release's migrate command as its own step, or override this to "true" for
# a single-replica deployment where that is acceptable.
ENV CARTULARY_AUTO_MIGRATE=false
EXPOSE 4000
# Readiness, not liveness: this endpoint reports healthy only once the database, the job
# supervisor, and the configured model roles are all usable, so an orchestrator will not
# route traffic to a process that is up but cannot serve. It exposes component status and
# error classes only, never credentials or stored content. Timings are seconds: probe
# every 10, fail a single probe after 3, ignore failures during the first 30 while the VM
# and connection pool come up, and mark the container unhealthy after 5 in a row.
HEALTHCHECK --interval=10s --timeout=3s --start-period=30s --retries=5 \
  CMD curl -fsS http://127.0.0.1:4000/api/ready || exit 1

# Exec form, so the release becomes PID 1 and receives the stop signal directly and shuts
# down in an orderly way instead of being killed after a timeout.
CMD ["/app/bin/cartulary", "start"]
