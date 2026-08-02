# Find eligible builder and runner images on Docker Hub. We use Ubuntu/Debian
# instead of Alpine to avoid DNS resolution issues in production.
#
# https://hub.docker.com/r/hexpm/elixir/tags?page=1&name=ubuntu
# https://hub.docker.com/_/ubuntu?tab=tags
#
# This file is based on these images:
#
#   - https://hub.docker.com/r/hexpm/elixir/tags - for the build image
#   - https://hub.docker.com/_/debian?tab=tags&page=1&name=bullseye-20260610-slim - for the release image
#   - https://pkgs.org/ - resource for finding needed packages
#   - Ex: hexpm/elixir:1.20.0-erlang-29.0.1-debian-bullseye-20260610-slim
#
ARG ELIXIR_VERSION=1.20.0
ARG OTP_VERSION=29.0.1
# Bookworm, not Bullseye: exqlite's precompiled NIF needs GLIBC_2.33+.
# Bullseye only ever shipped 2.31.x regardless of snapshot date, which
# crash-looped every machine on first real deploy with "version
# `GLIBC_2.33' not found" -- caught via an actual fly deploy, not
# something a local build would have surfaced.
ARG DEBIAN_VERSION=bookworm-20260610-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

# ---- Granville build stage ----
# Built from its own tagged GitHub release, not a local sibling directory --
# this Dockerfile has to work for anyone who clones only this repo, not just
# on a machine that happens to have ../granville checked out too.
#
# Platform pinned explicitly to linux/amd64: Fly Machines are x86_64
# regardless of what machine runs `docker build`, and leaving this to
# native-arch auto-detection produced a mismatched/unrunnable binary when
# built on Apple Silicon.
ARG BUILD_PLATFORM=linux/amd64
FROM --platform=${BUILD_PLATFORM} debian:${DEBIAN_VERSION} AS granville-builder

RUN apt-get update -y && apt-get install -y curl xz-utils ca-certificates git \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

ARG ZIG_VERSION=0.15.2
RUN curl -fL -o /tmp/zig.tar.xz "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
    && mkdir -p /usr/local/zig \
    && tar -xJf /tmp/zig.tar.xz -C /usr/local/zig --strip-components=1 \
    && rm /tmp/zig.tar.xz
ENV PATH="/usr/local/zig:${PATH}"

# Pin to a tagged release, not main -- reproducible builds shouldn't track a
# moving branch. Bump this deliberately when a new Granville version ships.
ARG GRANVILLE_VERSION=v0.3.0
RUN git clone --branch ${GRANVILLE_VERSION} --depth 1 \
    https://github.com/rjpruitt16/granville.git /granville
WORKDIR /granville
RUN zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseFast
# Fetches the prebuilt granville-llama driver from its own GitHub release --
# no need to compile llama.cpp/cmake/g++ in this image.
ENV HOME=/root
RUN ./zig-out/bin/granville driver install granville-llama

FROM ${BUILDER_IMAGE} AS builder

# install build dependencies
RUN apt-get update -y && apt-get install -y build-essential wget git \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

# Install litestream
ARG LITESTREAM_VERSION=0.3.13
RUN wget https://github.com/benbjohnson/litestream/releases/download/v${LITESTREAM_VERSION}/litestream-v${LITESTREAM_VERSION}-linux-amd64.deb \
    && dpkg -i litestream-v${LITESTREAM_VERSION}-linux-amd64.deb

# prepare build dir
WORKDIR /app

# install hex + rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# set build ENV
ENV MIX_ENV="prod"

# install mix dependencies
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# copy compile-time config files before we compile dependencies
# to ensure any relevant config change will trigger the dependencies
# to be re-compiled.
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY priv priv

COPY lib lib

COPY assets assets

# compile assets
RUN mix assets.deploy

# Compile the release
RUN mix compile

# Changes to config/runtime.exs don't require recompiling the code
COPY config/runtime.exs config/

COPY rel rel
RUN mix release

# start a new build stage so that the final image will only contain
# the compiled release and other runtime necessities
FROM ${RUNNER_IMAGE}

RUN apt-get update -y && \
  apt-get install -y libstdc++6 libgomp1 openssl libncurses5 locales ca-certificates curl \
  && apt-get clean && rm -f /var/lib/apt/lists/*_*

# Set the locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG en_US.UTF-8
ENV LANGUAGE en_US:en
ENV LC_ALL en_US.UTF-8

WORKDIR "/app"
RUN chown nobody /app

# set runner ENV
ENV MIX_ENV="prod"

# Only copy the final release from the build stage
COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/uhuru ./

# Copy Litestream binary from build stage
COPY --from=builder /usr/bin/litestream /usr/bin/litestream
COPY litestream.sh /app/bin/litestream.sh
COPY config/litestream.yml /etc/litestream.yml

# Copy Granville + the granville-llama driver it fetched at build time.
# HOME=/app makes Granville's driver lookup (~/.granville/drivers/...)
# resolve somewhere the nobody user can actually read.
ENV HOME=/app
COPY --from=granville-builder /granville/zig-out/bin/granville /app/bin/granville
COPY --from=granville-builder --chown=nobody:root /root/.granville /app/.granville
COPY boot.sh /app/bin/boot.sh

USER nobody

# If using an environment that doesn't automatically reap zombie processes, it is
# advised to add an init process such as tini via `apt-get install`
# above and adding an entrypoint. See https://github.com/krallin/tini for details
# ENTRYPOINT ["/tini", "--"]

# boot.sh starts Granville (downloading the model on first boot if needed),
# waits for it to be ready, then hands off to the existing Litestream +
# Phoenix startup -- this replaces the old direct litestream.sh entrypoint.
ENTRYPOINT ["/bin/bash", "/app/bin/boot.sh"]

CMD ["/app/bin/server"]
