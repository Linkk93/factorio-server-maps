# Factorio mapshot render sidecar image.
#
# debian:bookworm + Xvfb (ships xvfb-run) + Mesa/llvmpipe software GL: the
# full Factorio client needs a rendering-capable X display, which xvfb-run
# provides inside the container. mapshot itself is a pinned static Go binary.
#
# Runs as root deliberately: the read-only AMP instance mount contains
# amp-owned files (root can always read them), and the /output bind is
# written root-owned (making it readable for Caddy is documented in the
# README).
#
# Build:  docker build -t factorio-mapshot:dev .
# Run:    docker compose run --rm mapshot render

FROM debian:bookworm

# Pinned mapshot release. Sourced from the Linkk93 fork, NOT upstream
# Palats/mapshot: upstream's latest (0.0.28, Nov 2025) declares
# factorio_version "2.0" in mod/info.json and Factorio 2.1 refuses to load
# such mods; the fork is identical code with that one line bumped to "2.1".
# Switch the URL back to Palats/mapshot when upstream ships a 2.1-capable
# release. NOTE: GitHub tags carry NO "v" prefix (upstream convention), and
# the linux-amd64 asset is a single raw binary named "mapshot-linux".
ARG MAPSHOT_VERSION=0.0.28-2.1

ENV SDL_AUDIODRIVER=dummy \
    LIBGL_ALWAYS_SOFTWARE=1

# - xvfb provides Xvfb + xvfb-run (virtual display for the Factorio client).
# - The explicit GL set forces Mesa/llvmpipe software rendering (see mapshot
#   issues #8/#16/#53); mesa-utils ships glxinfo for debugging.
# - curl/ca-certificates for the pinned mapshot download and, later, the
#   Factorio client download; unzip/xz-utils for save integrity checks and
#   client archives.
# - jq/zstd deliberately absent (no consumer in this project).
# - nice/ionice/flock come from util-linux in the base image.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        xz-utils \
        unzip \
        xvfb \
        xauth \
        libgl1 \
        libglx-mesa0 \
        libgl1-mesa-dri \
        libglu1-mesa \
        libxrandr2 \
        libxinerama1 \
        libxcursor1 \
        libxi6 \
        mesa-utils \
    && rm -rf /var/lib/apt/lists/*

# mapshot release binary (linux amd64), pinned at build time. The smoke test
# proves the download yielded a working binary (`version` is a mapshot
# subcommand; upstream has no --version flag).
RUN curl -fsSL -o /usr/local/bin/mapshot \
        "https://github.com/Linkk93/mapshot/releases/download/${MAPSHOT_VERSION}/mapshot-linux" \
    && chmod 0755 /usr/local/bin/mapshot \
    && mapshot version

COPY render.sh /usr/local/bin/render.sh
RUN chmod 0755 /usr/local/bin/render.sh

# ENTRYPOINT without a default arg: `docker compose up` (no args) therefore
# runs the `check` subcommand — prints the resolved-config table and exits 0
# harmlessly. Timer and manual runs pass `render` explicitly.
ENTRYPOINT ["/usr/local/bin/render.sh"]
