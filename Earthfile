VERSION 0.8

os-deps:
  ARG TARGETPLATFORM
  ARG ELIXIR=1.18.4
  ARG OTP=28.0.1
  ARG ALPINE_BUILD=3.22.0
  FROM --platform=$TARGETPLATFORM hexpm/elixir:$ELIXIR-erlang-$OTP-alpine-$ALPINE_BUILD
  RUN apk add --no-progress --update git build-base

deps:
  # This steps is in charge of fetch the dependencies and this is their only purpose.
  FROM +os-deps
  WORKDIR /app

  # Copy the config file and the mix to retrieve the dependencies
  COPY config config
  COPY mix.exs mix.lock ./

  # Pre-requisites to compile the app.
  RUN --mount=type=cache,target=~/.hex/packages/hexpm \
      --mount=type=cache,target=~/.cache/rebar3 \
      mix do local.rebar --force, local.hex --force, deps.get

  SAVE ARTIFACT deps /deps

release:
  ARG RELEASE=defdo_ddns
  ARG MIX_ENV=prod
  FROM +deps
  COPY +deps/deps deps
  COPY lib lib
  RUN mix do compile, release ${RELEASE}

  SAVE ARTIFACT "_build/${MIX_ENV}/rel/${RELEASE}" /release

build-all-platforms:
    ARG REPO=paridin/defdo_ddns
    ARG TAG=latest
    BUILD --platform=linux/amd64 --platform=linux/arm64 +docker --REPO=${REPO} --TAG=${TAG}

docker:
  ARG TARGETPLATFORM
  ARG REPO=paridin/defdo_ddns
  ARG TAG=latest
  ARG ALPINE_RELEASE=3.22.0
  FROM --platform=$TARGETPLATFORM alpine:${ALPINE_RELEASE}
  WORKDIR /opt/app
  RUN apk upgrade --update && \
    apk add -U --no-cache \
    tzdata \
    bash \
    curl \
    # from elixir 1.12 otp 24 glib is required because the JIT.
    libgcc libstdc++ ncurses-libs \
    openssl-dev && \
    rm -rf /var/cache/apk/*
  # configure timezone https://wiki.alpinelinux.org/wiki/Setting_the_timezone
  RUN cp /usr/share/zoneinfo/America/Mexico_City /etc/localtime && \
    echo "America/Mexico_City " > /etc/timezone && \
    apk del tzdata

  WORKDIR /opt/app

  COPY +release/release /opt/app

  CMD trap 'exit' INT; bin/$(ls bin) start
  SAVE IMAGE --push ${REPO}:latest
  SAVE IMAGE --push ${REPO}:${TAG}
