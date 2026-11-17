###########
# CRYSTAL #
###########

# Base images are pinned by digest, so the binaries of a release are built from
# the very image the CI built and tested with — a tag alone can be re-pointed.
# To move to a newer build of the same tag, read its digest with
#   docker buildx imagetools inspect alpine:3.24
# and replace it here (same for the distroless image below).
FROM alpine:3.24@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf AS crystal

# crystal is held to the patch release pinned in mise.toml, so the image
# binary comes from the compiler the test suite ran on.
RUN apk add --update --no-cache \
  bash \
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

# The static binary of the docker image only. The released binaries are built
# by crystalreleaser (.crystalreleaser.yml), in an image of its own.
FROM crystal AS build-binary-file

WORKDIR /build
COPY .git/ /build/.git/
COPY shard.yml shard.lock LICENSE licenses.manifest /build/
COPY licenses-spdx/ /build/licenses-spdx/
COPY licenses-upstream/ /build/licenses-upstream/
COPY scripts/harvest-licenses.sh /build/scripts/
COPY src/ /build/src/

# The harvest reads lib/<shard>/LICENSE: shards first. licenses/ is read by
# the compiler (AptLarder::Licenses), so it must exist before the build.
RUN mkdir -p bin \
 && shards install --production \
 && bash scripts/harvest-licenses.sh \
 && crystal build --threads 4 --release --error-trace --static -o bin/apt-larder src/apt-larder.cr

###########
# RUNTIME #
###########

# Build distroless images \o/
FROM gcr.io/distroless/static-debian12:latest@sha256:d75cdd72874d4790092fcb1b058493ecf6bb5bf2b2b897045b00ff01d91843f2 AS docker-image

# Grab the apt-larder binary from the build step and inject it in the final image
COPY --from=build-binary-file /build/bin/apt-larder /usr/bin/apt-larder

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
