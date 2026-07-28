# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

ARG ELIXIR_IMAGE=hexpm/elixir:1.18.4-erlang-27.3.4-debian-bookworm-20250428-slim
ARG DEBIAN_IMAGE=debian:bookworm-20250428-slim
ARG RUST_IMAGE=rust:1.85-slim-bookworm

FROM ${RUST_IMAGE} AS rust-toolchain

FROM ${ELIXIR_IMAGE} AS build

COPY --from=rust-toolchain /usr/local/cargo /usr/local/cargo
COPY --from=rust-toolchain /usr/local/rustup /usr/local/rustup

RUN apt-get -o Acquire::Retries=5 update \
    && apt-get -o Acquire::Retries=5 install -y --no-install-recommends build-essential git curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
ENV MIX_ENV=prod
ENV MIX_HTTP_TIMEOUT=120000
ENV HEX_HTTP_TIMEOUT=120
ENV HEX_HTTP_CONCURRENCY=1
ENV CARGO_HOME=/usr/local/cargo
ENV RUSTUP_HOME=/usr/local/rustup
ENV PATH=/usr/local/cargo/bin:${PATH}
ENV CARGO_HTTP_TIMEOUT=120
ENV CARGO_NET_RETRY=5

RUN (mix local.hex --force \
      || mix local.hex --force \
      || mix local.hex --force) \
    && (mix local.rebar --force \
      || mix local.rebar --force \
      || mix local.rebar --force)
COPY mix.exs mix.lock ./
RUN --mount=type=cache,target=/root/.cache/rustler_precompiled \
    --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    mix deps.get --only prod && mix deps.compile

COPY config config
COPY lib lib
COPY priv priv
COPY rel rel
RUN mix compile && mix release

FROM ${DEBIAN_IMAGE} AS runtime

RUN apt-get -o Acquire::Retries=5 update \
    && apt-get -o Acquire::Retries=5 install -y --no-install-recommends libstdc++6 openssl libncurses6 curl ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --create-home --uid 10001 cartulary \
    && mkdir -p /var/lib/cartulary/blobs \
    && chown -R cartulary:cartulary /var/lib/cartulary

WORKDIR /app
COPY --from=build --chown=cartulary:cartulary /build/_build/prod/rel/cartulary ./

USER cartulary
ENV HOME=/home/cartulary
ENV PHX_SERVER=true
ENV CARTULARY_DATABASE_MODE=external
ENV CARTULARY_AUTO_MIGRATE=false
EXPOSE 4000
HEALTHCHECK --interval=10s --timeout=3s --start-period=30s --retries=5 \
  CMD curl -fsS http://127.0.0.1:4000/api/ready || exit 1

CMD ["/app/bin/cartulary", "start"]
