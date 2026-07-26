# syntax=docker/dockerfile:1.7
#
# Release image for defdo_ddns, ported from the Earthfile it replaces.
#
# The Earthly build produced both architectures in one pass under QEMU. That is
# the one thing this ecosystem does not do: the BEAM JIT segfaults under QEMU
# user-mode emulation on aarch64, so each architecture is now built on its own
# native BuildKit daemon and joined with manifest-tool — see
# .woodpecker/docker-image.yml. This file is therefore single-arch by design and
# is invoked once per architecture.
#
# All dependencies are public, so no Hex organization auth is needed here.
ARG ELIXIR_VERSION=1.18.4
ARG OTP_VERSION=28.0.1
ARG ALPINE_BUILD=3.22.0
ARG ALPINE_RELEASE=3.22.0
ARG MIX_ENV=prod
ARG RELEASE=defdo_ddns
ARG TIMEZONE=America/Mexico_City

FROM hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-alpine-${ALPINE_BUILD} AS deps
ARG MIX_ENV
ENV MIX_ENV=${MIX_ENV}
WORKDIR /app

RUN apk add --no-progress --update git build-base

COPY config config
COPY mix.exs mix.lock ./

RUN --mount=type=cache,target=/root/.hex/packages/hexpm \
    --mount=type=cache,target=/root/.cache/rebar3 \
    mix do local.rebar --force, local.hex --force, deps.get --only ${MIX_ENV}

FROM deps AS release
ARG MIX_ENV
ARG RELEASE
ENV MIX_ENV=${MIX_ENV}

COPY lib lib

RUN --mount=type=cache,target=/root/.hex/packages/hexpm \
    --mount=type=cache,target=/root/.cache/rebar3 \
    mix do compile, release ${RELEASE}

RUN cp -a "_build/${MIX_ENV}/rel/${RELEASE}" /release

FROM alpine:${ALPINE_RELEASE} AS runtime
ARG RELEASE
ARG TIMEZONE
ENV RELEASE=${RELEASE}

RUN apk upgrade --update && \
    apk add -U --no-cache \
      tzdata \
      bash \
      curl \
      # libgcc/libstdc++/ncurses are required by the JIT from OTP 24 on.
      libgcc libstdc++ ncurses-libs \
      openssl-dev && \
    cp /usr/share/zoneinfo/${TIMEZONE} /etc/localtime && \
    echo "${TIMEZONE}" > /etc/timezone && \
    apk del tzdata && \
    rm -rf /var/cache/apk/*

WORKDIR /opt/app
COPY --from=release /release /opt/app

# The Earthfile derived the binary name with `ls bin`; the release name is known
# here, so it is named outright.
CMD ["sh", "-lc", "trap 'exit' INT; exec bin/${RELEASE} start"]
