ARG ELIXIR_VERSION=1.18.4
ARG OTP_VERSION=27.3.4
ARG DEBIAN_VERSION=bookworm-20250428-slim

FROM hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION} AS build

RUN apt-get update -y && apt-get install -y build-essential git \
  && apt-get clean && rm -f /var/lib/apt/lists/*_*

WORKDIR /app

ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
COPY config config
RUN mix deps.get --only prod
RUN mix deps.compile

COPY assets assets
COPY agent_packs agent_packs
COPY lib lib
COPY priv priv
RUN mix assets.deploy
RUN mix compile
RUN mix release

FROM debian:${DEBIAN_VERSION} AS app

RUN apt-get update -y && apt-get install -y libstdc++6 openssl libncurses6 locales ca-certificates curl \
  && apt-get clean && rm -f /var/lib/apt/lists/*_*

ENV LANG=C.UTF-8
ENV MIX_ENV=prod
ENV PHX_SERVER=true

WORKDIR /app
COPY --from=build /app/_build/prod/rel/hydra_agent ./
COPY --from=build /app/agent_packs ./agent_packs
RUN useradd --system --create-home --home-dir /home/hydra hydra \
  && chown -R hydra:hydra /app /home/hydra

USER hydra

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD curl -fsS http://127.0.0.1:${PORT:-4000}/api/health >/dev/null || exit 1

CMD ["/app/bin/hydra_agent", "start"]
