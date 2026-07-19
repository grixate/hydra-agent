ARG ELIXIR_VERSION=1.18.4
ARG OTP_VERSION=27.3.4
ARG DEBIAN_VERSION=bookworm-20250428-slim

FROM hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION} AS build

RUN apt-get update -y \
  && apt-get upgrade -y \
  && apt-get install -y --no-install-recommends build-essential git \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
COPY config config
RUN mix deps.get --only prod

# User-mode cross-architecture builders may set this to "+JMsingle true".
ARG ERL_FLAGS=""
RUN mix deps.compile

COPY lib lib
COPY priv priv
COPY assets assets
RUN mix assets.deploy
RUN mix compile
RUN mix release

FROM debian:${DEBIAN_VERSION} AS app

RUN apt-get update -y \
  && apt-get upgrade -y \
  && apt-get install -y --no-install-recommends \
  libstdc++6 openssl libncurses6 locales ca-certificates curl \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

ENV LANG=C.UTF-8
ENV MIX_ENV=prod
ENV PHX_SERVER=true

WORKDIR /app
COPY --from=build /app/_build/prod/rel/hydra_agent ./

RUN groupadd --system hydra \
  && useradd --system --gid hydra --home-dir /app hydra \
  && chown -R hydra:hydra /app

USER hydra

HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=5 \
  CMD curl -fsS -H 'x-forwarded-proto: https' http://127.0.0.1:4000/readyz || exit 1

CMD ["/app/bin/hydra_agent", "start"]
