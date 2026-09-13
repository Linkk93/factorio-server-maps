#!/usr/bin/env bash
# validate.sh — SERVER-side pre-flight check for the mapshot sidecar.
# Run on the server after cloning (README "Server setup"). Hard failures exit
# non-zero immediately; warnings are normal on a dev PC or before the first
# render (the real mount/config checks run inside docker).
set -uo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 1

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
ok() { printf 'OK:   %s\n' "$*"; }

command -v docker >/dev/null 2>&1 || fail 'docker not found — install Docker Engine + the compose plugin (README: Prerequisites)'
ok "docker: $(docker --version)"
docker compose version >/dev/null 2>&1 || fail 'docker compose v2 plugin not found — install the docker-compose-plugin package'
ok 'docker compose v2 present'

[[ -f .env ]] || fail '.env missing — run: cp .env.example .env   (then fill AMP_INSTANCE_NAME and FACTORIO_USERNAME/FACTORIO_TOKEN)'
ok '.env present'

bash -n render.sh || fail 'render.sh: bash syntax error'
ok 'render.sh: bash -n clean'

if command -v shellcheck >/dev/null 2>&1; then
	shellcheck render.sh || fail 'render.sh: fix the shellcheck findings above'
	ok 'render.sh: shellcheck clean'
else
	warn 'shellcheck not found — lint skipped; install it: sudo apt install shellcheck'
fi

# Host-path sanity — warnings only; verified for real inside the container.
set -a
# shellcheck source=/dev/null
. ./.env
set +a
OUTPUT_DIR_HOST="${OUTPUT_DIR_HOST:-/srv/factorio-maps}"
INSTANCE_DIR="${AMP_DATA_ROOT:-/home/amp/.ampdata/instances}/${AMP_INSTANCE_NAME:-}"
[[ -d "${INSTANCE_DIR}" ]] || warn "AMP instance dir not found on this host: ${INSTANCE_DIR} — check AMP_DATA_ROOT / AMP_INSTANCE_NAME in .env"
[[ -d "${OUTPUT_DIR_HOST}" ]] || warn "output dir does not exist yet: ${OUTPUT_DIR_HOST} (docker creates it on the first render)"
[[ -d "${OUTPUT_DIR_HOST}" && ! -w "${OUTPUT_DIR_HOST}" ]] && warn "${OUTPUT_DIR_HOST} is not writable by $(id -un) — usually fine, the container runs as root"

docker compose config -q || fail 'docker compose config invalid — fix the errors printed above (often an empty required var in .env)'
ok 'docker compose config: valid'
ok 'validation passed'
