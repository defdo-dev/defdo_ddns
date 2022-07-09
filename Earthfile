VERSION 0.6
ARG REPO=paridin/defdo_ddns
ARG MIX_ENV=prod
ARG RELEASE=defdo_ddns
ARG ALPINE_BUILD=3.16.0
ARG ALPINE_RELEASE=3.16.0

os-deps:
  ARG TARGETPLATFORM
  ARG ELIXIR=1.13.4
  ARG OTP=24.3.4.2
  FROM --platform=$TARGETPLATFORM hexpm/elixir:$ELIXIR-erlang-$OTP-alpine-$ALPINE_BUILD
  # In the following line we require a git because our repository has git dependencies.
  # also build-base because we use argon2 which requires a compile toolchain.
  # if you don't require them, you can remove it.
  # It will speed the build process because we don fetched the dependencies.
  # We will see on the log from the RUN command how many packages are instaled and most of them come from build-base
  # g++, make. ca-certificates among others.
  # to learn more about read the next post <#TODO create a document to explain it>.
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
  FROM +deps
  COPY +deps/deps deps
  COPY lib lib
  RUN mix do compile, release ${RELEASE}

  SAVE ARTIFACT "_build/${MIX_ENV}/rel/${RELEASE}" /release

build-all-platforms:
    BUILD --platform=linux/amd64 --platform=linux/arm64 +docker

docker:
  ARG TARGETPLATFORM
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