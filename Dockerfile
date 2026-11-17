###########
# CRYSTAL #
###########

# Base images are pinned by digest, so the binaries of a release are built from
# the very image the CI built and tested with — a tag alone can be re-pointed.
# To move to a newer build of the same tag, read its digest with
#   docker buildx imagetools inspect alpine:3.24
# and replace it here (same for the distroless image below).
FROM alpine:3.24@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf AS crystal

# crystal is held to the patch release pinned in mise.toml, so the release
# binaries come from the compiler the test suite ran on.
RUN apk add --update --no-cache \
  make \
  crystal=~1.20.3 \
  shards \
  gc-dev \
  gc-static \
  git \
  libxml2-dev \
  libxml2-static \
  openssl-dev \
  openssl-libs-static \
  gmp-dev \
  gmp-static \
  pcre2-dev \
  pcre2-static \
  xz-dev \
  xz-static \
  yaml-dev \
  yaml-static \
  zlib-dev \
  zlib-static

#########
# BUILD #
#########

FROM crystal AS build-binary-file

# Fetch platforms variables from ARGS
ARG TARGETPLATFORM
ARG TARGETOS
ARG TARGETARCH
ARG TARGETVARIANT

# Export them to build binary files with the right name: apt-larder-linux-amd64
ENV \
  TARGETPLATFORM=${TARGETPLATFORM} \
  TARGETOS=${TARGETOS} \
  TARGETARCH=${TARGETARCH} \
  TARGETVARIANT=${TARGETVARIANT}

# Set build environment
WORKDIR /build
COPY .git/ /build/.git/
COPY shard.yml shard.lock /build/
COPY Makefile.release /build/Makefile
COPY src/ /build/src/
RUN mkdir /build/bin

# Build the binary
RUN make release

# Extract binary from Docker image
FROM scratch AS binary-file
ARG TARGETOS
ARG TARGETARCH
COPY --from=build-binary-file /build/bin/apt-larder-${TARGETOS}-${TARGETARCH} /

###########
# RUNTIME #
###########

# Build distroless images \o/
FROM gcr.io/distroless/static-debian12:latest@sha256:d75cdd72874d4790092fcb1b058493ecf6bb5bf2b2b897045b00ff01d91843f2 AS docker-image

# Fetch platforms variables from ARGS
ARG TARGETOS
ARG TARGETARCH

# Grab apt-larder binary from **binary-file** step and inject it in the final image
COPY --from=build-binary-file /build/bin/apt-larder-${TARGETOS}-${TARGETARCH} /usr/bin/apt-larder

# Set runtime environment
USER nonroot
ENV USER=nonroot
ENV HOME=/home/nonroot
WORKDIR /home/nonroot

# The probe is the binary itself, not curl: this image is distroless, so it has
# no shell, no curl and no wget — apt-larder is the only thing in here that can
# speak HTTP. Exec form for the same reason (the shell form would need /bin/sh).
#
# It probes the proxy (GET /_health on server_port), not the admin server:
# gating health on an optional surface reported unhealthy on every deployment
# without an admin server, while the proxy was serving packages perfectly.
#
# No --config is passed: the probe reads apt-larder.yml from the working
# directory (/home/nonroot) when one is mounted there, the APT_LARDER_*
# variables, and the defaults otherwise. A config mounted elsewhere that moves
# server_port needs the healthcheck overridden with `-c <path>`.
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD ["apt-larder", "healthcheck"]

ENTRYPOINT ["apt-larder"]
