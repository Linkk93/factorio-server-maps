#!/usr/bin/env bash
#
# render.sh — entrypoint for the Factorio mapshot render sidecar.
#
# Subcommands:
#   check          (default) validate config, print the resolved-value table,
#                  check container mounts and tool availability
#   render         run the mapshot render pipeline: lock + preflight guards,
#                  save selection, unchanged-save skip (time travel), sandbox
#                  assembly, mapshot invocation, atomic publish + retention,
#                  timeline regeneration
#   -h | --help    show usage
#
# Anything else is passed through verbatim to the mapshot binary, e.g.:
#   render.sh version
#
# Configuration comes from the environment (inside the container, injected by
# docker compose env_file) or from a .env file next to this script (host-side
# runs like `bash render.sh check`). Every knob and its default is documented
# in .env.example — that file is the single source of truth.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"

# Container-fixed mount points (contract with docker-compose.yml). They are
# deliberately not .env knobs, but honor the environment so host-side tests
# can point version detection and client caching at fixture trees.
INSTANCE_DIR="${INSTANCE_DIR:-/instance}"
CACHE_DIR="${CACHE_DIR:-/cache}"
# /run contract (docker compose tmpfs): the runtime-written curl config that
# carries the download credentials (mode 0600) must live on tmpfs, never on
# the writable layer or persistent disk. Honors the environment so host-side
# tests can point it at a writable directory.
RUN_DIR="${RUN_DIR:-/run}"
# /output contract (the docker compose bind of OUTPUT_DIR_HOST): renders/,
# .staging/ scratch, .render.lock and the latest symlink all live here.
# Co-locating staging and final output on one filesystem is what makes
# publication a same-filesystem rename. Honors the environment like
# INSTANCE_DIR/CACHE_DIR so host-side tests can point it at a fixture tree.
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
STAGING_ROOT="${OUTPUT_DIR}/.staging"
# Resolved once per run by resolve_instance_dirs(): AMP nests server data at
# <instance>/factorio/server/... in newer layouts, so saves/ and mods/ must
# never be hardcoded. INSTANCE_SAVES_DIR / INSTANCE_MODS_DIR double as env
# overrides (in-container paths) — see .env.example.
INSTANCE_SAVES_DIR="${INSTANCE_SAVES_DIR:-}"
INSTANCE_MODS_DIR="${INSTANCE_MODS_DIR:-}"
# SANDBOX_DATADIR is both the mapshot --factorio_datadir AND the root of a
# full portable Factorio client copy (bin/, data/, mods/, saves/): mapshot
# polls <datadir>/script-output for its done marker, and the portable Linux
# client writes script-output next to its bin/ — so the datadir must be the
# client install root itself, and --factorio_binary must point at the copy.
SANDBOX_DATADIR="${STAGING_ROOT}/datadir"
RENDERS_DIR="${OUTPUT_DIR}/renders"
LOCK_FILE="${OUTPUT_DIR}/.render.lock"

err()  { printf 'render.sh: ERROR: %s\n' "$*" >&2; }
warn() { printf 'render.sh: WARN:  %s\n' "$*" >&2; }
info() { printf 'render.sh: %s\n' "$*"; }
fatal() { err "$*"; exit 1; }

usage() {
	cat <<'EOF'
render.sh — Factorio mapshot render sidecar

Usage:
  render.sh [check]          validate config, print resolved values, check
                             mounts and tool availability (default)
  render.sh render           run the mapshot render pipeline (save select ->
                             sandbox -> render -> atomic publish + retention)
  render.sh pin <dir>        mark a render as pinned ("do not delete"): never
                             rotated out, does not consume a retention slot
  render.sh unpin <dir>      remove the pin (subject to rotation again)
  render.sh pins             list pinned renders
  render.sh -h | --help      this help
  render.sh <args...>        anything else is passed through verbatim to the
                             mapshot binary, e.g. `render.sh version`
                             (note: mapshot has a `version` subcommand, no
                             `--version` flag)

Configuration is read from the environment (container, via compose env_file)
or from .env next to this script (host runs). See .env.example for every knob
and its default.
EOF
}

# load_config: source .env when present (host-side convenience; inside the
# container the variables arrive via compose env_file and there is no .env
# next to this script), then apply the documented defaults for anything still
# unset. File values win over inherited env on the host.
load_config() {
	local env_file="${SCRIPT_DIR}/.env"
	if [[ -f "${env_file}" ]]; then
		info "loading config from ${env_file}"
		set -a
		# shellcheck source=/dev/null
		. "${env_file}"
		set +a
	fi

	# Defaults — keep in sync with .env.example (single source of truth).
	AMP_DATA_ROOT="${AMP_DATA_ROOT:-/home/amp/.ampdata/instances}"
	AMP_INSTANCE_NAME="${AMP_INSTANCE_NAME:-}"
	SAVE_NAME="${SAVE_NAME:-}"
	FACTORIO_VERSION="${FACTORIO_VERSION:-}"
	# Empty = auto-detect from the instance's mod-list.json (see
	# resolve_edition); "alpha" | "expansion" force an edition.
	FACTORIO_EDITION="${FACTORIO_EDITION:-}"
	FACTORIO_USERNAME="${FACTORIO_USERNAME:-}"
	FACTORIO_TOKEN="${FACTORIO_TOKEN:-}"
	MAPSHOT_AREA="${MAPSHOT_AREA:-entities}"
	MAPSHOT_SURFACE="${MAPSHOT_SURFACE:-_all_}"
	MAPSHOT_TILEMIN="${MAPSHOT_TILEMIN:-64}"
	MAPSHOT_TILEMAX="${MAPSHOT_TILEMAX:-0}"
	MAPSHOT_JPGQUALITY="${MAPSHOT_JPGQUALITY:-85}"
	MAPSHOT_MINJPGQUALITY="${MAPSHOT_MINJPGQUALITY:-85}"
	MAPSHOT_EXTRA_ARGS="${MAPSHOT_EXTRA_ARGS:-}"
	OUTPUT_DIR_HOST="${OUTPUT_DIR_HOST:-/srv/factorio-maps}"
	RETENTION_COUNT="${RETENTION_COUNT:-10}"
	OVERLAY_SAVE_FILTER="${OVERLAY_SAVE_FILTER:-}"
	CLIENT_CACHE_COUNT="${CLIENT_CACHE_COUNT:-2}"
	MIN_FREE_GB="${MIN_FREE_GB:-10}"
	LP_NUM_THREADS="${LP_NUM_THREADS:-}"
	XVFB_SCREEN="${XVFB_SCREEN:-1920x1080x24}"
	RENDER_TIMEOUT_SECS="${RENDER_TIMEOUT_SECS:-21600}"
}

# resolve_instance_dirs: resolve INSTANCE_SAVES_DIR / INSTANCE_MODS_DIR once
# per run, logging each resolved path and how it was found. AMP versions nest
# server data differently (<instance>/saves, <instance>/factorio/saves,
# <instance>/factorio/server/saves — and likewise for mods), so the order is:
# explicit env override (fatal when it does not exist / lacks mod-list.json)
# → the known layout candidates → a bounded find over INSTANCE_DIR (for mods
# the reliable marker is a mod-list.json inside the dir). Fatals listing
# every tried path plus the override hint when nothing matches.
resolve_instance_dirs() {
	# --- saves -------------------------------------------------------------
	if [[ -n "${INSTANCE_SAVES_DIR:-}" ]]; then
		if [[ ! -d "${INSTANCE_SAVES_DIR}" ]]; then
			fatal "INSTANCE_SAVES_DIR='${INSTANCE_SAVES_DIR}' is set but not a directory (in-container path under ${INSTANCE_DIR}) — fix or unset the override in .env"
		fi
		info "saves dir: ${INSTANCE_SAVES_DIR} (source: INSTANCE_SAVES_DIR override)"
	else
		local saves_dir='' saves_src='scan' d
		for d in "${INSTANCE_DIR}/saves" "${INSTANCE_DIR}/factorio/saves" "${INSTANCE_DIR}/factorio/server/saves"; do
			if [[ -d "${d}" ]]; then
				saves_dir="${d}"
				saves_src='layout candidate'
				break
			fi
		done
		if [[ -z "${saves_dir}" ]]; then
			saves_dir="$(find "${INSTANCE_DIR}" -maxdepth 5 -type d -name saves -print -quit 2>/dev/null || true)"
		fi
		if [[ -z "${saves_dir}" ]]; then
			fatal "no saves directory found under ${INSTANCE_DIR} — tried ${INSTANCE_DIR}/saves, ${INSTANCE_DIR}/factorio/saves, ${INSTANCE_DIR}/factorio/server/saves plus a depth-5 scan; check AMP_INSTANCE_NAME or set INSTANCE_SAVES_DIR in .env"
		fi
		INSTANCE_SAVES_DIR="${saves_dir}"
		info "saves dir: ${INSTANCE_SAVES_DIR} (source: ${saves_src})"
	fi

	# --- mods ---------------------------------------------------------------
	# The reliable marker is mod-list.json inside the dir — a bare directory
	# named mods is not proof (mapshot/tmp dirs can share the name).
	if [[ -n "${INSTANCE_MODS_DIR:-}" ]]; then
		if [[ ! -f "${INSTANCE_MODS_DIR}/mod-list.json" ]]; then
			fatal "INSTANCE_MODS_DIR='${INSTANCE_MODS_DIR}' is set but contains no mod-list.json (in-container path under ${INSTANCE_DIR}) — fix or unset the override in .env"
		fi
		info "mods dir: ${INSTANCE_MODS_DIR} (source: INSTANCE_MODS_DIR override)"
	else
		local mods_dir='' mods_src='layout candidate'
		for d in "${INSTANCE_DIR}/mods" "${INSTANCE_DIR}/factorio/mods" "${INSTANCE_DIR}/factorio/server/mods"; do
			if [[ -f "${d}/mod-list.json" ]]; then
				mods_dir="${d}"
				break
			fi
		done
		if [[ -z "${mods_dir}" ]]; then
			mods_src='scan'
			while IFS= read -r d; do
				if [[ -f "${d}/mod-list.json" ]]; then
					mods_dir="${d}"
					break
				fi
			done < <(find "${INSTANCE_DIR}" -maxdepth 5 -type d -name mods -print 2>/dev/null)
		fi
		if [[ -z "${mods_dir}" ]]; then
			fatal "no mods directory containing mod-list.json found under ${INSTANCE_DIR} — tried ${INSTANCE_DIR}/mods, ${INSTANCE_DIR}/factorio/mods, ${INSTANCE_DIR}/factorio/server/mods plus a depth-5 scan; check AMP_INSTANCE_NAME or set INSTANCE_MODS_DIR in .env"
		fi
		INSTANCE_MODS_DIR="${mods_dir}"
		info "mods dir: ${INSTANCE_MODS_DIR} (source: ${mods_src})"
	fi
}

# instance_info_json: print the path of the instance's Factorio info.json.
# Known AMP layouts first (<instance>/factorio/data/base/info.json, then
# <instance>/data/base/info.json), then a bounded find fallback for
# AMP-version-dependent layouts. Pure file read — no execution, no network.
# INSTANCE_DIR is honored so tests can point this at a fixture tree.
instance_info_json() {
	local candidate="${INSTANCE_DIR}/factorio/data/base/info.json"
	if [[ -f "${candidate}" ]]; then
		printf '%s\n' "${candidate}"
		return 0
	fi
	candidate="${INSTANCE_DIR}/data/base/info.json"
	if [[ -f "${candidate}" ]]; then
		printf '%s\n' "${candidate}"
		return 0
	fi
	local hit=''
	hit="$(find "${INSTANCE_DIR}" -maxdepth 6 -type f -path '*data/base/info.json' -print -quit 2>/dev/null || true)"
	if [[ -n "${hit}" ]]; then
		printf '%s\n' "${hit}"
	fi
}

# ver_ge A B: return 0 when dotted version A >= B (sort -V ordering).
# Needed by ensure_factorio's post-download verification.
ver_ge() {
	local a="${1:?usage: ver_ge A B}"
	local b="${2:?usage: ver_ge A B}"
	[[ "$(printf '%s\n%s\n' "${a}" "${b}" | sort -V)" == "$(printf '%s\n%s\n' "${b}" "${a}")" ]]
}

# resolve_version_alias <experimental|stable> <edition>: map a FACTORIO_VERSION
# alias to the current concrete version (stdout) via factorio.com's public
# latest-releases endpoint (no auth). All diagnostics go to stderr. The API
# answer is parsed by KEY NAME, never by position: cut the wanted branch
# object first, then read the edition key inside it — key order inside the
# branch objects is not part of the contract. Returns 1 (caller fatals) for
# an unknown alias, curl failure, unparseable JSON, or a missing edition key.
resolve_version_alias() {
	local alias_name="${1:?usage: resolve_version_alias <experimental|stable> <edition>}"
	local edition="${2:?usage: resolve_version_alias <experimental|stable> <edition>}"
	local branch="${alias_name,,}"
	case "${branch}" in
		experimental | stable) ;;
		*) return 1 ;;
	esac

	local api_json
	if ! api_json="$(curl -sS --max-time 30 'https://factorio.com/api/latest-releases')"; then
		return 1
	fi
	if [[ -z "${api_json}" ]]; then
		return 1
	fi

	local branch_obj
	branch_obj="$(printf '%s\n' "${api_json}" | grep -oE "\"${branch}\":\{[^}]*\}" | head -n 1 || true)"
	if [[ -z "${branch_obj}" ]]; then
		return 1
	fi

	local ver
	ver="$(printf '%s\n' "${branch_obj}" \
		| grep -oE "\"${edition}\":\"[0-9.]+\"" \
		| head -n 1 \
		| sed -E 's/^"[^"]+":"([0-9.]+)"$/\1/' || true)"
	if [[ -z "${ver}" ]]; then
		return 1
	fi
	printf '%s\n' "${ver}"
}

# detect_version: resolve the Factorio version into the globals
# FACTORIO_VERSION_RESOLVED / FACTORIO_VERSION_SOURCE.
# Order: (a) FACTORIO_VERSION override → (b) the instance's own info.json
# (pure file read — preferred over executing a host-built binary that may
# not run under the container's glibc) → (c) any bin/x64/factorio under the
# instance via --version (last resort). Returns 1 with an actionable error
# when nothing works. Detection never touches the network — with one
# exception: a FACTORIO_VERSION alias ("experimental" | "stable",
# case-insensitive) is resolved to a concrete version via the
# latest-releases API BEFORE the client cache lookup, so the download URL
# and the cache key (<version>-<edition>) stay numeric and deterministic.
# The alias arm also resolves the edition (which never depends on the
# version) and publishes it in _FM_EDITION_RESOLVED for cmd_render to reuse.
# A verbatim override must be numeric — everything downstream (cache key,
# ver_ge verify) would silently break on anything else.
detect_version() {
	FACTORIO_VERSION_RESOLVED=''
	FACTORIO_VERSION_SOURCE=''
	_FM_EDITION_RESOLVED=''

	if [[ -n "${FACTORIO_VERSION}" ]]; then
		local lower="${FACTORIO_VERSION,,}"
		case "${lower}" in
			experimental | stable)
				local alias_edition
				if ! alias_edition="$(resolve_edition)"; then
					err "cannot resolve FACTORIO_VERSION=${FACTORIO_VERSION} via factorio.com/api/latest-releases — check connectivity or set a concrete version"
					return 1
				fi
				_FM_EDITION_RESOLVED="${alias_edition}"
				local concrete
				if ! concrete="$(resolve_version_alias "${lower}" "${alias_edition}")"; then
					err "cannot resolve FACTORIO_VERSION=${FACTORIO_VERSION} via factorio.com/api/latest-releases — check connectivity or set a concrete version"
					return 1
				fi
				FACTORIO_VERSION_RESOLVED="${concrete}"
				FACTORIO_VERSION_SOURCE="override (alias ${lower} -> ${concrete})"
				info "Factorio version: ${FACTORIO_VERSION_RESOLVED} (source: ${FACTORIO_VERSION_SOURCE})"
				return 0
				;;
		esac
		# Verbatim override. Guard (defense in depth): the value reaches the
		# cache key, the download URL and ver_ge — all assume numeric x.y.z.
		if [[ ! "${FACTORIO_VERSION}" =~ ^[0-9]+(\.[0-9]+)+$ ]]; then
			err "FACTORIO_VERSION='${FACTORIO_VERSION}' is neither a numeric x.y.z version nor an experimental|stable alias — set a concrete version like 2.0.28 or one of the aliases"
			return 1
		fi
		FACTORIO_VERSION_RESOLVED="${FACTORIO_VERSION}"
		FACTORIO_VERSION_SOURCE='override'
		info "Factorio version: ${FACTORIO_VERSION_RESOLVED} (source: ${FACTORIO_VERSION_SOURCE})"
		return 0
	fi

	local info_json
	info_json="$(instance_info_json)"
	if [[ -n "${info_json}" ]]; then
		local parsed
		parsed="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)".*/\1/p' "${info_json}" 2>/dev/null | head -n 1 || true)"
		if [[ -n "${parsed}" ]]; then
			FACTORIO_VERSION_RESOLVED="${parsed}"
			FACTORIO_VERSION_SOURCE='instance-info.json'
			info "Factorio version: ${FACTORIO_VERSION_RESOLVED} (source: ${FACTORIO_VERSION_SOURCE}: ${info_json})"
			return 0
		fi
		warn "${info_json}: no parsable \"version\" field — falling back to a binary probe"
	fi

	local bin
	bin="$(find "${INSTANCE_DIR}" -maxdepth 6 -type f -path '*bin/x64/factorio' -print -quit 2>/dev/null || true)"
	if [[ -n "${bin}" ]]; then
		local vout=''
		if vout="$("${bin}" --version 2>/dev/null)"; then
			local parsed_bin
			parsed_bin="$(printf '%s\n' "${vout}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true)"
			if [[ -n "${parsed_bin}" ]]; then
				FACTORIO_VERSION_RESOLVED="${parsed_bin}"
				FACTORIO_VERSION_SOURCE='instance-binary'
				info "Factorio version: ${FACTORIO_VERSION_RESOLVED} (source: ${FACTORIO_VERSION_SOURCE}: ${bin})"
				return 0
			fi
			warn "${bin}: --version output contains no x.y.z version token"
		else
			warn "${bin}: cannot execute --version (host-built binary vs container glibc?)"
		fi
	fi

	err 'cannot determine Factorio version — set FACTORIO_VERSION in .env'
	return 1
}

# resolve_edition: print (stdout) the download edition to use, "alpha" or
# "expansion"; all diagnostics go to stderr so the stdout contract survives
# `$( ... )` capture. Order: (a) FACTORIO_EDITION override (alpha|expansion)
# → (b) the instance's mods/mod-list.json: an enabled "space-age" mod entry
# means the save needs the Space Age client ("expansion"), anything else
# renders with "alpha" (per https://wiki.factorio.com/Download_API, alpha =
# full build WITHOUT Space Age, expansion = WITH). A missing mod-list.json
# defaults to alpha with a warning — prepare_sandbox still fatals on a
# missing mod-list.json later, so nothing is silently accepted here.
resolve_edition() {
	if [[ -n "${FACTORIO_EDITION:-}" ]]; then
		case "${FACTORIO_EDITION}" in
			alpha | expansion)
				info "Factorio edition: ${FACTORIO_EDITION} (source: FACTORIO_EDITION override)" >&2
				printf '%s\n' "${FACTORIO_EDITION}"
				return 0
				;;
			*)
				warn "FACTORIO_EDITION='${FACTORIO_EDITION}' is not alpha|expansion — ignoring it and auto-detecting" >&2
				;;
		esac
	fi

	# INSTANCE_MODS_DIR is resolved by resolve_instance_dirs before this runs
	# in every command path; the ${INSTANCE_DIR}/mods fallback keeps direct
	# host-side calls (e.g. the check alias arm without /instance) working.
	local mod_list="${INSTANCE_MODS_DIR:-${INSTANCE_DIR}/mods}/mod-list.json"
	if [[ ! -f "${mod_list}" ]]; then
		warn "${mod_list}: not found — cannot auto-detect the edition, defaulting to alpha" >&2
		printf 'alpha\n'
		return 0
	fi

	# The probe pairs each {...} object with its own fields, so it works for
	# both pretty-printed and minified mod-list.json and requires enabled:true
	# on the same object that carries the space-age name.
	if awk '
		{
			line = $0
			while (match(line, /\{[^{}]*\}/)) {
				obj = substr(line, RSTART, RLENGTH)
				line = substr(line, RSTART + RLENGTH)
				if (obj ~ /"name"[ \t]*:[ \t]*"space-age"/ && obj ~ /"enabled"[ \t]*:[ \t]*true/) { found = 1; exit }
			}
		}
		END { exit found ? 0 : 1 }
	' "${mod_list}"; then
		info "Factorio edition: expansion (source: enabled space-age mod in ${mod_list})" >&2
		printf 'expansion\n'
	else
		info "Factorio edition: alpha (source: no enabled space-age mod in ${mod_list})" >&2
		printf 'alpha\n'
	fi
}

cmd_check() {
	load_config

	local failures=0

	# --- required config ------------------------------------------------
	if [[ -z "${AMP_INSTANCE_NAME}" ]]; then
		err "AMP_INSTANCE_NAME is not set — set it in .env (the AMP instance directory name under AMP_DATA_ROOT)"
		failures=1
	fi

	local instance_dir="${AMP_DATA_ROOT}/${AMP_INSTANCE_NAME}"

	# --- resolved configuration table ------------------------------------
	printf '\n== resolved configuration ==\n'
	printf '%-24s %s\n' 'AMP_DATA_ROOT' "${AMP_DATA_ROOT}"
	printf '%-24s %s\n' 'AMP_INSTANCE_NAME' "${AMP_INSTANCE_NAME:-<unset — REQUIRED>}"
	printf '%-24s %s\n' 'instance dir (host)' "${instance_dir}"
	printf '%-24s %s\n' 'SAVE_NAME' "${SAVE_NAME:-<empty: newest stable save>}"
	printf '%-24s %s\n' 'FACTORIO_VERSION' "${FACTORIO_VERSION:-<empty: auto-detect>}"
	printf '%-24s %s\n' 'FACTORIO_EDITION' "${FACTORIO_EDITION:-<empty: auto-detect (space-age mod)>}"
	# Credentials are never printed — only whether they are present.
	local username_state token_state
	if [[ -n "${FACTORIO_USERNAME}" ]]; then username_state='(set)'; else username_state='(unset)'; fi
	if [[ -n "${FACTORIO_TOKEN}" ]]; then token_state='(set)'; else token_state='(unset)'; fi
	printf '%-24s %s\n' 'FACTORIO_USERNAME' "${username_state}"
	printf '%-24s %s\n' 'FACTORIO_TOKEN' "${token_state}"
	printf '%-24s %s\n' 'MAPSHOT_AREA' "${MAPSHOT_AREA}"
	printf '%-24s %s\n' 'MAPSHOT_SURFACE' "${MAPSHOT_SURFACE}"
	printf '%-24s %s\n' 'MAPSHOT_TILEMIN' "${MAPSHOT_TILEMIN}"
	printf '%-24s %s\n' 'MAPSHOT_TILEMAX' "${MAPSHOT_TILEMAX}"
	printf '%-24s %s\n' 'MAPSHOT_JPGQUALITY' "${MAPSHOT_JPGQUALITY}"
	printf '%-24s %s\n' 'MAPSHOT_MINJPGQUALITY' "${MAPSHOT_MINJPGQUALITY}"
	printf '%-24s %s\n' 'MAPSHOT_EXTRA_ARGS' "${MAPSHOT_EXTRA_ARGS:-<empty>}"
	printf '%-24s %s\n' 'OUTPUT_DIR_HOST' "${OUTPUT_DIR_HOST}"
 	printf '%-24s %s\n' 'RETENTION_COUNT' "${RETENTION_COUNT}"
	printf '%-24s %s\n' 'OVERLAY_SAVE_FILTER' "${OVERLAY_SAVE_FILTER:-<empty: overlay lists all saves>}"
	printf '%-24s %s\n' 'CLIENT_CACHE_COUNT' "${CLIENT_CACHE_COUNT}"
	printf '%-24s %s\n' 'MIN_FREE_GB' "${MIN_FREE_GB}"
	printf '%-24s %s\n' 'LP_NUM_THREADS' "${LP_NUM_THREADS:-<empty: llvmpipe default>}"
	printf '%-24s %s\n' 'XVFB_SCREEN' "${XVFB_SCREEN}"
	printf '%-24s %s\n' 'RENDER_TIMEOUT_SECS' "${RENDER_TIMEOUT_SECS}"

	# --- instance dirs --------------------------------------------------------
	# Resolves INSTANCE_SAVES_DIR / INSTANCE_MODS_DIR (fatal inside the
	# container when the instance layout cannot be discovered). Host mode
	# without /instance skips gracefully, matching the mount-check gating
	# below — resolution then happens inside the container.
	printf '\n== instance dirs ==\n'
	if [[ -d "${INSTANCE_DIR}" ]]; then
		resolve_instance_dirs
		printf '%-24s %s\n' 'saves dir' "${INSTANCE_SAVES_DIR}"
		printf '%-24s %s\n' 'mods dir' "${INSTANCE_MODS_DIR}"
	else
		info "${INSTANCE_DIR}: not present — instance dirs are resolved inside the container"
	fi

	# --- factorio version ----------------------------------------------------
	# Instance-grounded detection; on the host (no /instance) only the
	# FACTORIO_VERSION override can resolve, otherwise detection is deferred
	# to the container run.
	printf '\n== factorio version ==\n'
	if [[ -n "${FACTORIO_VERSION}" || -d "${INSTANCE_DIR}" ]]; then
		if detect_version; then
			printf '%-24s %s\n' 'resolved version' "${FACTORIO_VERSION_RESOLVED} (source: ${FACTORIO_VERSION_SOURCE})"
		else
			failures=1
		fi
	else
		info "no FACTORIO_VERSION override and ${INSTANCE_DIR} absent — version detection happens inside the container"
	fi

	# --- mounts -----------------------------------------------------------
	# INSTANCE_DIR only exists inside the container; on the host these checks
	# are skipped with a visible note (best-effort host hints instead).
	# saves/mods were already resolved and validated above (resolve_instance_dirs
	# logs the found paths and fatals with every tried candidate), so only the
	# output/cache mounts are checked here.
	printf '\n== mounts ==\n'
	if [[ -d "${INSTANCE_DIR}" ]]; then
		if [[ -d "${OUTPUT_DIR}" ]]; then
			if [[ -w "${OUTPUT_DIR}" ]]; then
				info "${OUTPUT_DIR}: OK (writable)"
			else
				err "${OUTPUT_DIR}: exists but is not writable"
				failures=1
			fi
		else
			err "${OUTPUT_DIR}: missing — check the OUTPUT_DIR_HOST bind in docker-compose.yml"
			failures=1
		fi
		if [[ -d "${CACHE_DIR}" ]]; then
			if [[ -w "${CACHE_DIR}" ]]; then
				info "${CACHE_DIR}: OK (writable)"
			else
				err "${CACHE_DIR}: exists but is not writable"
				failures=1
			fi
		else
			err "${CACHE_DIR}: missing — check the factorio-clients volume in docker-compose.yml"
			failures=1
		fi
	else
		info "${INSTANCE_DIR}: not present — not running inside the container, skipping mount checks"
		if [[ -n "${AMP_INSTANCE_NAME}" ]]; then
			if [[ -d "${instance_dir}" ]]; then
				info "instance dir ${instance_dir}: exists"
				if [[ ! -d "${instance_dir}/saves" ]]; then
					warn "${instance_dir}/saves: not found on this host"
				fi
			else
				warn "instance dir ${instance_dir}: not found on this host (validated inside the container)"
			fi
		fi
		if [[ -e "${OUTPUT_DIR_HOST}" ]]; then
			if [[ ! -w "${OUTPUT_DIR_HOST}" ]]; then
				warn "${OUTPUT_DIR_HOST}: exists but is not writable by this user (the container runs as root)"
			fi
		else
			warn "${OUTPUT_DIR_HOST}: does not exist yet (docker creates the bind source on first run)"
		fi
	fi

	# --- credentials --------------------------------------------------------
	# Credentials are only needed when a client download will actually happen
	# (no matching cached client); cached clients render without them, so a
	# miss is a warning, not an error.
	printf '\n== credentials ==\n'
	if [[ -n "${FACTORIO_USERNAME}" && -n "${FACTORIO_TOKEN}" ]]; then
		info 'FACTORIO_USERNAME / FACTORIO_TOKEN: set (values never printed)'
	else
		warn 'FACTORIO_USERNAME / FACTORIO_TOKEN: not fully set — required for the first Factorio client download (cached clients render without them)'
	fi

	# --- tool availability --------------------------------------------------
	# This is the single host/container downgrade point: inside the container
	# missing tools are fatal (broken image), on the host they are merely
	# noted because rendering runs in the container.
	printf '\n== tools ==\n'
	local tool
	local missing_tools=()
	for tool in mapshot unzip curl xvfb-run nice ionice flock; do
		if command -v "${tool}" >/dev/null 2>&1; then
			info "${tool}: $(command -v "${tool}")"
		else
			missing_tools+=("${tool}")
			warn "${tool}: not found on PATH"
		fi
	done
	if [[ -d "${INSTANCE_DIR}" ]] && (( ${#missing_tools[@]} > 0 )); then
		err "tools missing inside the container: ${missing_tools[*]} — the image is broken"
		failures=1
	elif [[ ! -d "${INSTANCE_DIR}" ]] && (( ${#missing_tools[@]} > 0 )); then
		info 'missing host tools are non-fatal: rendering runs inside the container'
	fi

	# --- verdict ------------------------------------------------------------
	printf '\n'
	if (( failures != 0 )); then
		err 'check failed — fix the ERROR lines above'
		return 1
	fi
	info 'check: OK'
	return 0
}

# prune_client_cache: keep the newest CLIENT_CACHE_COUNT client dirs under
# <CACHE_DIR>/factorio (by mtime), remove the rest. Best-effort: a missing
# cache root is not an error; dot-prefixed download temp dirs are ignored.
prune_client_cache() {
	local cache_root="${CACHE_DIR}/factorio"
	if [[ ! -d "${cache_root}" ]]; then
		return 0
	fi

	local keep="${CLIENT_CACHE_COUNT:-2}"
	if [[ ! "${keep}" =~ ^[0-9]+$ ]]; then
		warn "CLIENT_CACHE_COUNT='${keep}' is not a number — using default 2"
		keep=2
	fi

	local -a keep_dirs=()
	local -a prune_dirs=()
	local line dir
	while IFS= read -r line; do
		dir="${line#* }"
		if (( ${#keep_dirs[@]} < keep )); then
			keep_dirs+=("${dir}")
		else
			prune_dirs+=("${dir}")
		fi
	done < <(find "${cache_root}" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%T@ %p\n' 2>/dev/null | sort -rn)

	if (( ${#prune_dirs[@]} == 0 )); then
		info "client cache: ${#keep_dirs[@]} client dir(s), nothing to prune"
		return 0
	fi
	local d
	for d in "${prune_dirs[@]}"; do
		info "client cache: pruning old client dir ${d}"
		rm -rf -- "${d}"
	done
}

# _FM_TMPDIR / _FM_CURLCFG: the temp paths of a running ensure_factorio
# download, kept as GLOBALS on purpose. ensure_factorio runs inside a
# command-substitution subshell; by the time its EXIT trap fires, the
# function has returned and its locals are destroyed — a trap referencing
# them would hit set -u unbound-variable errors. The trap below therefore
# reads these globals instead.
_FM_TMPDIR=''
_FM_CURLCFG=''

# factorio_dl_cleanup: EXIT-trap backstop for ensure_factorio's download
# arm — wipes the credentials curl config and the partial download tree on
# any abort. Runs inside the same subshell, so it only ever touches these
# globals; the parent shell's trap chain is untouched.
factorio_dl_cleanup() {
	trap - EXIT
	if [[ -n "${_FM_CURLCFG}" ]]; then
		rm -f -- "${_FM_CURLCFG}"
	fi
	if [[ -n "${_FM_TMPDIR}" ]]; then
		rm -rf -- "${_FM_TMPDIR}"
	fi
}

# factorio_dl_attempt <version> <edition> <outfile>: download one get-download
# tarball. factorio.com's download endpoint rejects HTTP basic auth and takes
# the credentials as username/token QUERY PARAMETERS
# (https://wiki.factorio.com/Download_API). The full authenticated URL is
# therefore written into the 0600 curl config on tmpfs (curl reads it via
# -K), so the token never appears in argv, command lines or logs — only in
# that file — and only the redacted base URL is ever logged. Returns curl's
# exit code: 22 = HTTP error via -f (e.g. 403/404 for pruned versions),
# anything else = network/tooling error.
factorio_dl_attempt() {
	local version="${1:?usage: factorio_dl_attempt <version> <edition> <outfile>}"
	local edition="${2:?usage: factorio_dl_attempt <version> <edition> <outfile>}"
	local out="${3:?usage: factorio_dl_attempt <version> <edition> <outfile>}"

	local base_url="https://factorio.com/get-download/${version}/${edition}/linux64"

	# curl config: write to a 0600 temp file, then rename into place, so the
	# credentials are never readable by anyone else, not even briefly.
	local cfg_tmp
	if ! cfg_tmp="$(mktemp "${RUN_DIR}/factorio.curlcfg.XXXXXX")"; then
		err 'cannot create a curl config temp file under /run (tmpfs)'
		return 1
	fi
	if ! { printf 'url = "%s?username=%s&token=%s"\n' "${base_url}" "${FACTORIO_USERNAME}" "${FACTORIO_TOKEN}" >"${cfg_tmp}" \
		&& chmod 0600 "${cfg_tmp}" && mv -f -- "${cfg_tmp}" "${_FM_CURLCFG}"; } then
		rm -f -- "${cfg_tmp}"
		err 'cannot install the factorio.com curl config'
		return 1
	fi

	# -K: curl takes the URL (credentials included) from the config file, so
	# no argument ever carries the token. --max-time bounds a stuck transfer.
	curl -sS -fL --max-time 3600 -K "${_FM_CURLCFG}" -o "${out}"
}

# ensure_factorio <version> <edition>: print (stdout) the path of a working
# full Factorio client binary; all diagnostics go to stderr so the stdout
# contract survives `$( ... )` capture. Cache hit: <CACHE_DIR>/factorio/
# <version>-<edition>/bin/x64/factorio whose --version matches — no network.
# Miss: download https://factorio.com/get-download/<version>/<edition>/linux64
# via a 0600 curl config under /run (credentials never appear in argv or
# logs — see factorio_dl_attempt), extract, verify (--version >= <version>
# via ver_ge), atomically rename into place. If the exact version is gone
# server-side (factorio.com prunes obsolete/experimental builds → HTTP
# 403/404), retries ONCE with 'latest' for the same edition and fails when
# that fallback is older than <version> (see below). Cache GC
# (prune_client_cache) runs once per render, on cmd_render's success path.
# Returns 1 on failure; the curl config and temp tree are wiped by the EXIT
# trap (factorio_dl_cleanup, via the globals above) on any abort.
ensure_factorio() {
	local version="${1:?usage: ensure_factorio <version> <edition>}"
	local edition="${2:?usage: ensure_factorio <version> <edition>}"

	local cache_root="${CACHE_DIR}/factorio"
	local client_dir="${cache_root}/${version}-${edition}"
	local client_bin="${client_dir}/bin/x64/factorio"

	# --- cache hit -----------------------------------------------------------
	if [[ -x "${client_bin}" ]]; then
		local vout=''
		if vout="$("${client_bin}" --version 2>/dev/null)" && [[ "${vout}" == *"${version}"* ]]; then
			touch "${client_dir}"   # freshness marker for mtime-based GC
			info "using cached Factorio ${version} (${edition}): ${client_bin}" >&2
			printf '%s\n' "${client_bin}"
			return 0
		fi
		warn "cached client ${client_bin} did not verify — re-downloading" >&2
		rm -rf -- "${client_dir}"
	fi

	# --- cache miss: credentials required -------------------------------------
	local -a missing=()
	if [[ -z "${FACTORIO_USERNAME}" ]]; then missing+=('FACTORIO_USERNAME'); fi
	if [[ -z "${FACTORIO_TOKEN}" ]]; then missing+=('FACTORIO_TOKEN'); fi
	if (( ${#missing[@]} > 0 )); then
		err "cannot download Factorio ${version} (${edition}): ${missing[*]} not set — set ${missing[*]} in .env (factorio.com credentials; only needed when no matching client is cached)"
		return 1
	fi

	if ! mkdir -p "${cache_root}"; then
		err "cannot create cache root ${cache_root}"
		return 1
	fi
	local tmp_dir
	if ! tmp_dir="$(mktemp -d "${cache_root}/.tmp-${version}-${edition}.XXXXXX")"; then
		err "cannot create a temp dir under ${cache_root}"
		return 1
	fi

	# Publish the temp paths into the globals the EXIT trap cleans (see
	# factorio_dl_cleanup above for why locals cannot be used here).
	_FM_TMPDIR="${tmp_dir}"
	_FM_CURLCFG="${RUN_DIR}/factorio.curlcfg"
	# Backstop: on any abort (set -e) or subshell exit, wipe the temp tree and
	# the curl config — credentials and partial downloads must never linger.
	trap factorio_dl_cleanup EXIT

	local tarball="${tmp_dir}/factorio.tar.xz"
	local dl_base="https://factorio.com/get-download"
	local used_fallback='no'
	local dl_rc=0

	# Exact version first. On an HTTP error (curl -f exit 22 — factorio.com
	# takes experimental builds down quickly, so exact versions can 403/404
	# even with valid credentials) retry once with 'latest' for the same
	# edition. Any other curl exit is a network/tooling error: no retry.
	info "downloading Factorio ${version} (${edition}) from ${dl_base}/${version}/${edition}/linux64 (this can take a while)" >&2
	factorio_dl_attempt "${version}" "${edition}" "${tarball}" || dl_rc=$?
	if (( dl_rc == 22 )); then
		warn "download of ${version} failed with an HTTP error (obsolete/experimental builds are taken down quickly) — retrying once with 'latest' (${edition})" >&2
		used_fallback='yes'
		dl_rc=0   # reset: cmd || dl_rc=$? below only assigns on failure
		factorio_dl_attempt 'latest' "${edition}" "${tarball}" || dl_rc=$?
	fi
	if (( dl_rc != 0 )); then
		err "download failed (curl exit ${dl_rc}): ${dl_base}/${version}/${edition}/linux64 — check FACTORIO_USERNAME / FACTORIO_TOKEN; if the credentials are fine, exact version ${version} may no longer be published (factorio.com prunes obsolete/experimental builds) — set FACTORIO_VERSION to a downloadable version"
		return 1
	fi
	rm -f -- "${_FM_CURLCFG}"   # credentials are no longer needed from here on
	_FM_CURLCFG=''

	if ! tar -xJf "${tmp_dir}/factorio.tar.xz" -C "${tmp_dir}" --strip-components=1; then
		err 'extracting the Factorio client failed — damaged download or missing xz'
		return 1
	fi
	rm -f -- "${tmp_dir}/factorio.tar.xz"

	local extracted="${tmp_dir}/bin/x64/factorio"
	if [[ ! -x "${extracted}" ]]; then
		err "unexpected archive layout: ${extracted} not found after extraction"
		return 1
	fi
	local got=''
	if ! got="$("${extracted}" --version 2>/dev/null)"; then
		err 'the downloaded Factorio binary does not run (--version failed)'
		return 1
	fi
	local got_ver
	got_ver="$(printf '%s\n' "${got}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true)"
	if [[ -z "${got_ver}" ]] || ! ver_ge "${got_ver}" "${version}"; then
		if [[ "${used_fallback}" == 'yes' ]]; then
			err "exact version ${version} no longer downloadable and latest (${got_ver:-<none>}) is older — update the AMP instance or set FACTORIO_VERSION to a downloadable version"
		else
			err "downloaded client reports version '${got_ver:-<none>}' but >= ${version} is required — check FACTORIO_VERSION and FACTORIO_EDITION"
		fi
		return 1
	fi
	if [[ "${used_fallback}" == 'yes' ]]; then
		warn "render binary is Factorio ${got_ver}, not the save's ${version} (exact version no longer downloadable) — the render may not match the save exactly" >&2
		# Cache under the binary's REAL version: the cache-hit check verifies
		# the cached binary against the directory name, so a 'latest' download
		# must not masquerade as ${version}.
		client_dir="${cache_root}/${got_ver}-${edition}"
		client_bin="${client_dir}/bin/x64/factorio"
	fi

	# A stale/incomplete dir at the target must go: mv into an existing dir
	# would nest the fresh install below bin/x64/factorio and corrupt the
	# cache layout. (A *good* dir never reaches this point — the cache-hit
	# arm above returns early.)
	rm -rf -- "${client_dir}"

	# Same filesystem (both under cache_root) → this rename is atomic.
	if ! mv -- "${tmp_dir}" "${client_dir}"; then
		err "cannot move ${tmp_dir} into place at ${client_dir}"
		return 1
	fi
	trap - EXIT
	_FM_TMPDIR=''
	touch "${client_dir}"
	info "cached Factorio ${version} (${edition}) at ${client_dir}" >&2
	printf '%s\n' "${client_bin}"
}

# --- render pipeline (tasks 6-7) ---------------------------------------------
#
# Fixed layout under /output (contract with docker-compose.yml / Caddy):
#   /output/.render.lock           flock target (concurrency guard)
#   /output/.staging/              per-run scratch, cleaned at start and exit
#   /output/.staging/datadir/      render sandbox: full portable Factorio
#                                  client copy (bin/, data/, mods/, saves/);
#                                  mapshot datadir AND Factorio install root
#   /output/renders/<ts>_<save>/   published renders (UTC timestamp, pinned
#                                  format → lexicographic == chronological)
#   /output/renders/<ts>_<save>/render-meta.txt   per-render facts (save name,
#                                  sha256, timestamps) — powers the skip when
#                                  the save is unchanged between runs
#   /output/index.html             timeline homepage (regenerated every run,
#                                  including skipped ones)
#   /output/latest                 symlink -> renders/<ts>_<save>, atomic swap

# Newest auto-picked save must be at least this old (seconds) before it is
# trusted: a fresher mtime means the live server is probably still writing
# it. With players online the server autosaves frequently, so the auto pick
# walks newest→oldest and takes the first save past this window (a slightly
# older render beats a failed nightly). An explicit SAVE_NAME bypasses the
# pick entirely (but is still zip-checked).
SAVE_STABILITY_SECS=120

# Extra free space demanded on /output beyond MIN_FREE_GB: the render sandbox
# now contains a full portable copy of the Factorio client (~2-2.5 GB) on top
# of the render output itself. Padded to 3 GB; documented in .env.example
# (MIN_FREE_GB) and the README (Disk management).
SANDBOX_CLIENT_RESERVE_GB=3

# Edition resolved as a side effect of detect_version's FACTORIO_VERSION
# alias arm (an alias needs the edition to pick the right key in the
# latest-releases API answer; the edition never depends on the version).
# Set there, read by cmd_render so resolve_edition runs exactly once per
# render. Always '' when no alias was involved.
_FM_EDITION_RESOLVED=''

# Per-render facts carried into publish_render for render-meta.txt (the
# metadata behind the unchanged-save skip). Set by cmd_render after save
# selection / edition resolution; always '' when unavailable — the
# corresponding meta key is then simply omitted.
_FM_SAVE_SHA256=''
_FM_EDITION=''
# Captured `mapshot version` output, if any run ever captures it. Nothing
# does today (an extra binary invocation per render is not worth one cosmetic
# meta field), so the mapshot_version meta key stays omitted.
_FM_MAPSHOT_VERSION=''

# preflight: concurrency lock, scratch cleanup, disk guards — in that order.
# The lock fd stays open for the whole process, so the lock is held until
# exit (flock releases it automatically when the process dies).
preflight() {
	if [[ ! -d "${OUTPUT_DIR}" ]]; then
		err "${OUTPUT_DIR}: missing — check the OUTPUT_DIR_HOST bind in docker-compose.yml"
		return 1
	fi
	exec {RENDER_LOCK_FD}>"${LOCK_FILE}"
	if ! flock -n "${RENDER_LOCK_FD}"; then
		info 'render already in progress'
		exit 0
	fi
	# Stale atomic-swap leftovers from an interrupted previous run.
	rm -f -- "${OUTPUT_DIR}"/.latest.tmp.*
	# Nothing in .staging survives between runs — wipe any earlier debris.
	rm -rf -- "${STAGING_ROOT}"
	# /output must hold the render output PLUS the sandbox's full client copy
	# (see SANDBOX_CLIENT_RESERVE_GB); /cache holds the cached clients.
	check_free_space "${OUTPUT_DIR}" "${SANDBOX_CLIENT_RESERVE_GB}"
	check_free_space "${CACHE_DIR}" 0
}

# check_free_space <mount> [extra-gb]: fatal when the mount has less free
# space than MIN_FREE_GB plus the optional extra reserve. The error names
# the mount and its free space so the fix is obvious from the log alone.
check_free_space() {
	local mount="${1:?usage: check_free_space <mount> [extra-gb]}"
	local extra="${2:-0}"
	if [[ ! "${MIN_FREE_GB}" =~ ^[0-9]+$ ]]; then
		fatal "MIN_FREE_GB='${MIN_FREE_GB}' is not a number — fix it in .env"
	fi
	if [[ ! "${extra}" =~ ^[0-9]+$ ]]; then
		fatal "internal error: free-space reserve '${extra}' is not a number"
	fi
	local need=$((MIN_FREE_GB + extra))
	local need_desc="${MIN_FREE_GB}GB (MIN_FREE_GB)"
	if (( extra > 0 )); then
		need_desc="${need}GB (MIN_FREE_GB=${MIN_FREE_GB} + ${extra}GB sandbox client-copy reserve)"
	fi
	local avail
	avail="$(df --output=avail -BG -- "${mount}" 2>/dev/null | tail -n 1 | tr -dc '0-9')" || true
	if [[ -z "${avail}" ]]; then
		fatal "cannot determine free space on ${mount} (df failed) — is the mount present?"
	fi
	if (( avail < need )); then
		fatal "only ${avail}GB free on ${mount}, ${need_desc} required — render skipped; free up space or lower MIN_FREE_GB in .env"
	fi
	info "disk guard OK: ${mount} has ${avail}GB free (>= ${need_desc} required)"
}

# select_save: choose the save to render; prints the absolute path on stdout,
# logs to stderr. SAVE_NAME wins (exact file in INSTANCE_SAVES_DIR, ".zip"
# appended when missing); otherwise the newest *.zip by mtime, ignoring
# *.tmp.zip (download/save temporaries). The auto pick walks newest→oldest
# and selects the FIRST save at least SAVE_STABILITY_SECS old: with players
# online the newest file is often a mid-write autosave, and rendering the
# previous stable save beats failing the run (a failed nightly is a lost
# night). Only when every save is inside the stability window does the pick
# fail — the server is then saving more often than the window, which is
# genuinely pathological and worth an operator's attention.
select_save() {
	# Resolved by resolve_instance_dirs (AMP nests saves/ at various depths).
	local saves_dir="${INSTANCE_SAVES_DIR:?INSTANCE_SAVES_DIR is not resolved — resolve_instance_dirs must run first}"

	local selected=''
	if [[ -n "${SAVE_NAME}" ]]; then
		local candidate="${SAVE_NAME}"
		if [[ "${candidate}" != *.zip ]]; then
			candidate="${candidate}.zip"
		fi
		selected="${saves_dir}/${candidate}"
		if [[ ! -f "${selected}" ]]; then
			err "SAVE_NAME='${SAVE_NAME}': ${selected} not found — check the exact save filename in ${saves_dir}" >&2
			return 1
		fi
		info "save selection: ${selected} (explicit SAVE_NAME)" >&2
	else
		# All saves newest-first (mtime sort; *.tmp.zip excluded as
		# download/save temporaries). The "mtime path" pairs are parsed
		# with read -r m p so paths with spaces survive intact.
		local -a cand_mtimes=() cand_paths=()
		local line m p
		while IFS=' ' read -r m p; do
			[[ -n "${p}" ]] || continue
			cand_mtimes+=("${m%%.*}")
			cand_paths+=("${p}")
		done < <(find "${saves_dir}" -maxdepth 1 -type f -name '*.zip' ! -name '*.tmp.zip' -printf '%T@ %p\n' 2>/dev/null | sort -rn)
		if (( ${#cand_paths[@]} == 0 )); then
			err "no *.zip save found in ${saves_dir}" >&2
			return 1
		fi

		local now
		now="$(date +%s)"
		local i age=''
		for ((i = 0; i < ${#cand_paths[@]}; i++)); do
			age=$(( now - cand_mtimes[i] ))
			if (( age >= SAVE_STABILITY_SECS )); then
				if (( i > 0 )); then
					info "newest save $(basename -- "${cand_paths[0]}") is only $(( now - cand_mtimes[0] ))s old (< ${SAVE_STABILITY_SECS}s stability window) — falling back to the next stable save" >&2
				fi
				selected="${cand_paths[i]}"
				info "save selection: ${selected} (newest stable save, mtime ${age}s old, candidate $((i + 1)) of ${#cand_paths[@]})" >&2
				break
			fi
		done
		if [[ -z "${selected}" ]]; then
			err "all ${#cand_paths[@]} save(s) in ${saves_dir} are younger than the ${SAVE_STABILITY_SECS}s stability window (newest: $(basename -- "${cand_paths[0]}"), $(( now - cand_mtimes[0] ))s old) — the server is saving unusually often; retry shortly or set SAVE_NAME" >&2
			return 1
		fi
	fi
	printf '%s\n' "${selected}"
}

# check_save_integrity <save.zip>: `unzip -t` the selected save before any
# heavy work — a truncated autosave must fail fast, not mid-render.
check_save_integrity() {
	local save_zip="${1:?usage: check_save_integrity <save.zip>}"
	if ! unzip -t "${save_zip}" >/dev/null 2>&1; then
		err "save ${save_zip} failed the zip integrity check (unzip -t) — the file looks truncated or corrupt; wait for the next autosave or set SAVE_NAME"
		return 1
	fi
	info "save integrity OK (unzip -t): $(basename -- "${save_zip}")"
}

# prepare_sandbox <save.zip> <client-binary>: assemble the render sandbox
# datadir under /output/.staging/datadir as a FULL PORTABLE COPY of the
# cached Factorio client (~2 GB, same host disk — accepted cost). mapshot
# polls <factorio_datadir>/script-output for its done marker, and the
# portable Linux client writes script-output next to its own bin/ — a
# mods+saves-only dir can never match, so the sandbox must BE the client
# install root (and the render must exec the copy's binary, not the cache
# one). Instance mods are overlaid into <sandbox>/mods (mapshot reads the
# mod list from the datadir's mods/mod-list.json, NOT from the save) and
# the save is COPIED in — the render never touches the read-only instance
# mount, and the live server may keep autosaving meanwhile.
prepare_sandbox() {
	local save_zip="${1:?usage: prepare_sandbox <save.zip> <client-binary>}"
	local client_bin="${2:?usage: prepare_sandbox <save.zip> <client-binary>}"
	# Resolved by resolve_instance_dirs (marker: mod-list.json inside the dir).
	local mods_src="${INSTANCE_MODS_DIR:?INSTANCE_MODS_DIR is not resolved — resolve_instance_dirs must run first}"
	if [[ ! -f "${mods_src}/mod-list.json" ]]; then
		err "${mods_src}/mod-list.json: missing — the render needs it even for vanilla saves; check the instance's mods/ directory"
		return 1
	fi
	# The sandbox root is the client install root: <bin>/../.. above the
	# cached binary (…/<version>-<edition>/bin/x64/factorio).
	local client_root="${client_bin%/bin/x64/factorio}"
	if [[ "${client_root}" == "${client_bin}" || ! -d "${client_root}" ]]; then
		err "cannot locate the Factorio client root from binary ${client_bin} (expected <root>/bin/x64/factorio)"
		return 1
	fi
	if ! mkdir -p -- "${SANDBOX_DATADIR}"; then
		err "cannot create sandbox dir ${SANDBOX_DATADIR} under ${STAGING_ROOT}"
		return 1
	fi
	if ! cp -a -- "${client_root}/." "${SANDBOX_DATADIR}/"; then
		err "cannot copy the Factorio client ${client_root} into the sandbox ${SANDBOX_DATADIR}"
		return 1
	fi
	info "sandbox: copied Factorio client root ${client_root} into ${SANDBOX_DATADIR} (~2 GB)"
	if ! mkdir -p -- "${SANDBOX_DATADIR}/mods" "${SANDBOX_DATADIR}/saves"; then
		err "cannot create mods/ and saves/ under ${SANDBOX_DATADIR}"
		return 1
	fi
	if ! cp -a -- "${mods_src}/." "${SANDBOX_DATADIR}/mods/"; then
		err "cannot sync mods from ${mods_src} into the sandbox"
		return 1
	fi
	local mod_count
	mod_count="$(find "${SANDBOX_DATADIR}/mods" -type f 2>/dev/null | wc -l)"
	info "sandbox: synced ${mod_count} mods file(s) from ${mods_src}"
	if ! cp -a -- "${save_zip}" "${SANDBOX_DATADIR}/saves/"; then
		err "cannot snapshot ${save_zip} into the sandbox"
		return 1
	fi
	info "sandbox: save snapshot $(basename -- "${save_zip}") (instance stays read-only)"
	if [[ ! -x "${SANDBOX_DATADIR}/bin/x64/factorio" ]]; then
		err "sandbox Factorio binary ${SANDBOX_DATADIR}/bin/x64/factorio missing after the client copy"
		return 1
	fi
}

# run_render <save-base> <render-binary>: the de-prioritized mapshot
# invocation. nice/ionice/timeout are applied INSIDE the container (systemd
# Nice=/IOSchedulingClass= never reach container processes). The binary
# passed here MUST be the sandbox copy (<SANDBOX_DATADIR>/bin/x64/factorio):
# Factorio (portable install) writes script-output next to its own bin/, and
# that is exactly where mapshot polls <factorio_datadir>/script-output.
# --work_dir is deliberately NOT passed: with work_dir == datadir, mapshot's
# mod copy would copy every mod onto itself (upstream copy.Copy has no
# identity guard → 0-byte zips). Without the flag mapshot creates its own
# temp dir and removes it on exit. LIBGL_ALWAYS_SOFTWARE / SDL_AUDIODRIVER
# are set in the image ENV and re-exported defensively so the software-GL
# path cannot be lost to an env_file variation.
run_render() {
	local save_base="${1:?usage: run_render <save-base> <render-binary>}"
	local render_bin="${2:?usage: run_render <save-base> <render-binary>}"

	export SDL_AUDIODRIVER=dummy
	export LIBGL_ALWAYS_SOFTWARE=1
	if [[ -n "${LP_NUM_THREADS}" ]]; then
		export LP_NUM_THREADS
		info "render: LP_NUM_THREADS=${LP_NUM_THREADS} (llvmpipe thread cap)"
	fi

	local -a render_cmd=(
		nice -n 19 ionice -c 3
		timeout "${RENDER_TIMEOUT_SECS}"
		xvfb-run -a -s "-screen 0 ${XVFB_SCREEN}"
		mapshot render "${save_base}"
		--logtostderr
		--factorio_datadir "${SANDBOX_DATADIR}"
		--factorio_binary "${render_bin}"
		--area "${MAPSHOT_AREA}"
		--tilemin "${MAPSHOT_TILEMIN}"
		--tilemax "${MAPSHOT_TILEMAX}"
		--jpgquality "${MAPSHOT_JPGQUALITY}"
		--minjpgquality "${MAPSHOT_MINJPGQUALITY}"
		--surface "${MAPSHOT_SURFACE}"
	)
	if [[ -n "${MAPSHOT_EXTRA_ARGS}" ]]; then
		# Verbatim escape hatch (documented knob): deliberate word splitting.
		# shellcheck disable=SC2206
		render_cmd+=(${MAPSHOT_EXTRA_ARGS})
	fi

	info "render: starting mapshot (timeout ${RENDER_TIMEOUT_SECS}s, nice 19, ionice 3) — this can take hours on a megabase"
	info "render command: ${render_cmd[*]}"
	"${render_cmd[@]}"
}

# dump_factorio_diagnostics: called when the mapshot invocation failed. On a
# hang (e.g. a modal UI dialog under Xvfb — mod errors, edition mismatch,
# graphics init failure) mapshot's stderr stops mid-flight, but Factorio keeps
# writing its own log inside the sandbox datadir. Dump its tail to our stderr
# so the failure is diagnosable without waiting out the timeout, plus the
# script-output tile count: 0 tiles ≈ still loading mods, many ≈ rendering.
dump_factorio_diagnostics() {
	local log="${SANDBOX_DATADIR}/factorio-current.log"
	local tiles
	tiles="$(find "${SANDBOX_DATADIR}/script-output" -type f 2>/dev/null | wc -l)"
	printf 'render.sh: --- factorio-current.log (last 60 lines) ---\n' >&2
	if [[ -f "${log}" ]]; then
		tail -n 60 -- "${log}" >&2
	else
		printf 'render.sh: NOTE: Factorio never created %s (itself a diagnostic: graphics never initialized / wrong binary)\n' "${log}" >&2
	fi
	printf 'render.sh: --- tile progress: %s file(s) under %s/script-output ---\n' "${tiles}" "${SANDBOX_DATADIR}" >&2
}

# locate_render_output <save-base>: print the produced render directory.
# Canonical mapshot layout: <datadir>/script-output/mapshot/<save-base>/ —
# with the sandbox as a full portable client copy, SANDBOX_DATADIR is the
# client install root, so this is where Factorio (writing next to its bin/)
# and mapshot agree the output lives. Fallback: any index.html under
# script-output, in case the prefix differs — publication still works.
locate_render_output() {
	local save_base="${1:?usage: locate_render_output <save-base>}"
	local expected="${SANDBOX_DATADIR}/script-output/mapshot/${save_base}"
	if [[ -f "${expected}/index.html" ]]; then
		printf '%s\n' "${expected}"
		return 0
	fi
	local hit=''
	hit="$(find "${SANDBOX_DATADIR}/script-output" -type f -name index.html -print -quit 2>/dev/null || true)"
	if [[ -n "${hit}" ]]; then
		warn "render output at an unexpected path: ${hit} (expected ${expected}/index.html)" >&2
		printf '%s\n' "$(dirname -- "${hit}")"
		return 0
	fi
	return 1
}

# publish_render <render-dir> <save-base>: move the render into its final
# timestamped home and swap the `latest` symlink. Both steps are atomic:
#   - staging and renders/ share the /output filesystem → mv is a rename(2),
#     never a multi-GB copy;
#   - latest is swapped via a temp-name symlink + mv -Tf — a single
#     rename(2), no unlink window (unlike ln -sfn); readers never observe a
#     missing or half-updated `latest`.
# render-meta.txt (save name, sha256, timestamps — the data the unchanged-save
# skip compares) is written into the new dir BEFORE the symlink swap, so a
# published render never lacks metadata. Prints the published directory on
# stdout.
publish_render() {
	local render_dir="${1:?usage: publish_render <render-dir> <save-base>}"
	local save_base="${2:?usage: publish_render <render-dir> <save-base>}"

	local ts publish_name
	ts="$(date -u +%Y%m%d-%H%M%S)"
	publish_name="${ts}_${save_base}"

	mkdir -p -- "${RENDERS_DIR}"
	mv -- "${render_dir}" "${RENDERS_DIR}/${publish_name}"

	local publish_dir="${RENDERS_DIR}/${publish_name}"
	local meta="${publish_dir}/render-meta.txt"
	if ! {
		printf 'save=%s\n' "${save_base}"
		printf 'sha256=%s\n' "${_FM_SAVE_SHA256}"
		printf 'date_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		if [[ -n "${FACTORIO_VERSION_RESOLVED}" ]]; then
			printf 'factorio_version=%s\n' "${FACTORIO_VERSION_RESOLVED}"
		fi
		if [[ -n "${_FM_EDITION}" ]]; then
			printf 'edition=%s\n' "${_FM_EDITION}"
		fi
		# mapshot_version is omitted unless a captured value exists (see the
		# _FM_MAPSHOT_VERSION global): the `mapshot version` subcommand is not
		# worth an extra invocation per render for a cosmetic field.
		if [[ -n "${_FM_MAPSHOT_VERSION}" ]]; then
			printf 'mapshot_version=%s\n' "${_FM_MAPSHOT_VERSION}"
		fi
	} >"${meta}"; then
		# Not fatal: a missing/unparsable meta file only means the next run
		# cannot skip and re-renders once.
		warn "cannot write ${meta} — the next render will not be able to skip (no skip metadata)"
	fi

	rm -f -- "${OUTPUT_DIR}"/.latest.tmp.*
	local tmp_link="${OUTPUT_DIR}/.latest.tmp.$$"
	ln -s "renders/${publish_name}" "${tmp_link}"
	mv -Tf -- "${tmp_link}" "${OUTPUT_DIR}/latest"

	printf '%s\n' "${publish_dir}"
}

# prune_renders: keep the newest RETENTION_COUNT dirs under renders/, delete
# the rest. Pins ("do not delete") are excluded from BOTH counting and
# pruning: a dir with a `pinned` marker file (see cmd_pin) is never rotated
# out and does not consume a slot — N slots + P pins = N+P renders before
# the oldest *unpinned* render rotates. Glob expansion is sorted
# lexicographically, which — with the pinned UTC timestamp format — equals
# chronological order, so oldest-first pruning is order-safe; `latest`'s
# target is additionally protected so the symlink can never dangle mid-prune.
prune_renders() {
	local keep="${RETENTION_COUNT}"
	if [[ ! "${keep}" =~ ^[0-9]+$ ]]; then
		warn "RETENTION_COUNT='${keep}' is not a number — using default 10"
		keep=10
	fi
	if (( keep < 1 )); then
		warn 'RETENTION_COUNT=0 would delete the fresh render — using 1'
		keep=1
	fi

	local -a unpinned=()
	local d pinned_count=0
	shopt -s nullglob
	for d in "${RENDERS_DIR}"/*; do
		[[ -d "${d}" ]] || continue
		if [[ -f "${d}/pinned" ]]; then
			pinned_count=$((pinned_count + 1))
		else
			unpinned+=("${d}")
		fi
	done
	shopt -u nullglob

	local total="${#unpinned[@]}"
	if (( total <= keep )); then
		info "retention: ${total} unpinned + ${pinned_count} pinned render dir(s), nothing to prune (RETENTION_COUNT=${keep})"
		return 0
	fi

	local latest_target=''
	latest_target="$(readlink -f -- "${OUTPUT_DIR}/latest" 2>/dev/null || true)"

	local prune_count=$(( total - keep ))
	local -a prune_dirs=()
	local i
	for ((i = 0; i < prune_count; i++)); do
		d="${unpinned[${i}]}"
		if [[ -n "${latest_target}" && "${d}" -ef "${latest_target}" ]]; then
			warn "retention: ${d} is the current 'latest' target — skipping"
			continue
		fi
		prune_dirs+=("${d}")
	done
	if (( ${#prune_dirs[@]} == 0 )); then
		info "retention: nothing to prune (${pinned_count} pinned dir(s) excluded from rotation)"
		return 0
	fi
	for d in "${prune_dirs[@]}"; do
		info "retention: pruning old render ${d}"
		rm -rf -- "${d}"
	done
	info "retention: pruned ${#prune_dirs[@]} old render dir(s), kept the newest (RETENTION_COUNT=${keep}, ${pinned_count} pinned exempt)"
}

# render_meta_read <render-dir>: print the sha256 recorded in
# <render-dir>/render-meta.txt (key=value lines). Empty output when the dir
# or file is missing or the content is unparsable (e.g. renders made before
# this metadata existed) — callers must treat empty as "changed save".
render_meta_read() {
	local render_dir="${1:?usage: render_meta_read <render-dir>}"
	local meta="${render_dir}/render-meta.txt"
	if [[ ! -r "${meta}" ]]; then
		return 0
	fi
	local key val
	while IFS='=' read -r key val; do
		if [[ "${key}" == 'sha256' && "${val}" =~ ^[0-9a-f]{64}$ ]]; then
			printf '%s\n' "${val}"
			return 0
		fi
	done <"${meta}"
	return 0
}

# html_escape <string>: print the string escaped for HTML text and attribute
# contexts. Save names come from filenames and dirnames from timestamps, but
# both are still dynamic input to a served page — escape everything. sed, not
# ${var//&/…}: bash 5.2's default patsub_replacement would expand the `&` in
# the replacement to the matched text (turning `&lt;` into `<lt;`).
html_escape() {
	local s="${1:-}"
	s="$(printf '%s' "${s}" \
		| sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&#39;/g")"
	printf '%s\n' "${s}"
}

# list_render_dirs: print the absolute paths of all published render dirs
# (one per line, oldest→newest — glob order over the pinned timestamp format
# is chronological). Only dirs matching <YYYYMMDD-HHMMSS>_<name> count;
# anything else under renders/ is not a render. Consumed by the timeline
# page, the timeline manifest and the overlay injection. Process
# substitution keeps it space-safe (save names may contain spaces).
list_render_dirs() {
	local d
	shopt -s nullglob
	for d in "${RENDERS_DIR}"/*; do
		if [[ -d "${d}" && "${d##*/}" =~ ^[0-9]{8}-[0-9]{6}_ ]]; then
			printf '%s\n' "${d}"
		fi
	done
	shopt -u nullglob
}

# json_escape <string>: print the string escaped for a JSON string literal.
# Save names originate from filenames; backslash and double quote are the
# only characters that must be escaped (control characters in filenames are
# pathological and rejected by the format check long before this). An empty
# or missing argument is valid input (prints nothing).
json_escape() {
	printf '%s' "${1-}" \
		| sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# write_timeline_json: write <OUTPUT_DIR>/timeline.json — the manifest the
# in-map time-travel overlay (/overlay.js) fetches: the configured
# save_filter (empty = overlay offers every render; see OVERLAY_SAVE_FILTER
# in .env.example) plus the newest-first list of {dir, save, date}.
# Regenerated by update_timeline_layer on every run (renders AND skips),
# atomically (temp + mv). Never fatal: a missing manifest only means the
# overlay stays hidden.
write_timeline_json() {
	local out="${OUTPUT_DIR}/timeline.json"
	local tmp="${out}.tmp.$$"

	if ! {
		printf '{"generated":"%s","save_filter":"%s","renders":[' \
			"$(date -u '+%Y-%m-%d %H:%M:%S UTC')" \
			"$(json_escape "${OVERLAY_SAVE_FILTER}")"
		local d base ts_raw save_name date_human pin_state first=1
		while IFS= read -r d; do
			base="${d##*/}"
			ts_raw="${base%%_*}"
			save_name="${base#*_}"
			date_human="${ts_raw:0:4}-${ts_raw:4:2}-${ts_raw:6:2} ${ts_raw:9:2}:${ts_raw:11:2}:${ts_raw:13:2} UTC"
			pin_state='false'
			if [[ -f "${d}/pinned" ]]; then
				pin_state='true'
			fi
			(( first )) || printf ','
			first=0
			printf '\n{"dir":"%s","save":"%s","date":"%s","pinned":%s}' \
				"$(json_escape "${base}")" "$(json_escape "${save_name}")" "$(json_escape "${date_human}")" "${pin_state}"
		done < <(tac < <(list_render_dirs))
		printf '\n]}\n'
	} >"${tmp}"; then
		warn "cannot write the timeline manifest ${tmp} — the map overlay will stay hidden"
		rm -f -- "${tmp}"
		return 0
	fi
	if ! mv -f -- "${tmp}" "${out}"; then
		warn "cannot install the timeline manifest at ${out} — the map overlay will stay hidden"
		rm -f -- "${tmp}"
	fi
}

# ensure_overlay_js: publish <OUTPUT_DIR>/overlay.js — the static, vanilla
# piece the injected snippet loads on every render page. Rewritten every run
# (idempotent content, atomic swap); never fatal.
ensure_overlay_js() {
	local out="${OUTPUT_DIR}/overlay.js"
	local tmp="${out}.tmp.$$"
	if ! cat >"${tmp}" <<'OVERLAY_EOF'
/* mapshot time-travel overlay — injected into every render's index.html by
 * render.sh (see inject_time_overlay). Fetches /timeline.json and offers a
 * date switcher plus a home button back to the timeline; which renders it
 * offers is data-driven via the manifest's
 * save_filter field (empty = every render of the instance, so autosaves and
 * renames of the same world stay one history; a name = that save only).
 * Switching forwards the live query string (x/y/z/s/layers kept by the
 * viewer via history.replaceState), so the view position survives the jump.
 * Stays hidden when the manifest is missing (e.g. a render dir served
 * standalone), the path is unknown, or there is nothing to switch between. */
(function () {
	"use strict";
	var match = location.pathname.match(/^\/renders\/([^/]+)\//);
	var currentDir = match ? decodeURIComponent(match[1]) : null;
	var onLatest = !match && /(^|\/)latest\/?$/.test(location.pathname);
	if (!currentDir && !onLatest) return;

	fetch("/timeline.json", { cache: "no-cache" })
		.then(function (r) { return r.json(); })
		.then(function (data) {
			var renders = (data && data.renders) || [];
			if (!renders.length) return;
			// Save filtering is DATA-DRIVEN: the manifest carries the
			// configured OVERLAY_SAVE_FILTER. Empty (default) = offer every
			// render of the instance — autosaves and renames of the same
			// world stay one history. Non-empty = restrict to that save.
			var sf = (data && data.save_filter) || "";
			if (sf) {
				renders = renders.filter(function (e) { return e.save === sf; });
			}
			if (renders.length < 2) return; // nothing to switch between

			var cur = 0;
			for (var i = 0; i < renders.length; i++) {
				if (renders[i].dir === currentDir) { cur = i; break; }
			}

			function go(i) {
				if (i < 0 || i >= renders.length || i === cur) return;
				location.href = "/renders/" + encodeURIComponent(renders[i].dir) +
					"/index.html" + location.search;
			}

			var pill = document.createElement("div");
			pill.style.cssText = "position:fixed;left:10px;bottom:10px;z-index:1000;" +
				"background:#16181d;color:#d7dae0;border:1px solid #2a2e35;border-radius:8px;" +
				"padding:6px 10px;font:12px/1.4 system-ui,sans-serif;display:flex;gap:6px;" +
				"align-items:center;box-shadow:0 2px 8px rgba(0,0,0,.4)";

			// Home: back to the timeline. Available regardless of history depth.
			var home = document.createElement("button");
			home.title = "Back to the timeline (/)";
			home.style.cssText = "background:none;border:none;cursor:pointer;" +
				"padding:0 2px;display:flex;align-items:center";
			home.innerHTML = '<svg width="14" height="14" viewBox="0 0 24 24" fill="none"' +
				' stroke="#4da3ff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' +
				'<path d="M3 11.5 12 4l9 7.5"/><path d="M5.5 10.5V20h13V9.5"/><path d="M10 20v-5h4v5"/></svg>';
			home.addEventListener("click", function () { location.href = "/"; });
			pill.appendChild(home);

			// The date switcher only makes sense with more than one render.
			if (renders.length >= 2) {
				function button(label, delta) {
					var b = document.createElement("button");
					b.textContent = label;
					b.addEventListener("click", function () { go(cur + delta); });
					b.style.cssText = "background:none;border:none;color:#4da3ff;" +
						"cursor:pointer;font-size:15px;padding:0 2px";
					return b;
				}
				var prev = button("\u2039", -1); // ‹
				var next = button("\u203A", 1);  // ›

				var select = document.createElement("select");
				select.title = "Jump to render date";
				select.style.cssText = "background:#16181d;color:#d7dae0;border:1px solid #2a2e35;" +
					"border-radius:4px;font:inherit;padding:2px 4px;cursor:pointer";
				renders.forEach(function (e, i) {
					var opt = document.createElement("option");
					opt.value = String(i);
					opt.textContent = e.date + (i === 0 ? " (latest)" : "");
					if (i === cur) opt.selected = true;
					select.appendChild(opt);
				});
				select.addEventListener("change", function () {
					go(parseInt(select.value, 10));
				});

				function refresh() {
					prev.disabled = cur === 0;
					next.disabled = cur === renders.length - 1;
					prev.style.color = prev.disabled ? "#4a5058" : "#4da3ff";
					next.style.color = next.disabled ? "#4a5058" : "#4da3ff";
					prev.style.cursor = prev.disabled ? "default" : "pointer";
					next.style.cursor = next.disabled ? "default" : "pointer";
				}
				refresh();

				pill.appendChild(prev);
				pill.appendChild(select);
				pill.appendChild(next);
			}
			document.body.appendChild(pill);
		})
		.catch(function () { /* no manifest / fetch failed: stay hidden */ });
})();
OVERLAY_EOF
	then
		warn "cannot write the overlay script ${tmp} — the map overlay will stay hidden"
		rm -f -- "${tmp}"
		return 0
	fi
	if ! mv -f -- "${tmp}" "${out}"; then
		warn "cannot install the overlay script at ${out} — the map overlay will stay hidden"
		rm -f -- "${tmp}"
	fi
}

# inject_time_overlay: append the overlay loader to every retained render's
# index.html — idempotent (marker check), atomic per file (temp + mv; the
# dirs are served live by Caddy). Runs on every run (via update_timeline_layer),
# so renders published before this feature are retrofitted on the next run,
# without re-rendering. Never fatal: an uninjectable dir keeps working, just
# without the overlay.
inject_time_overlay() {
	local marker='<!-- mapshot-tt-overlay -->'
	local d idx tmp
	while IFS= read -r d; do
		idx="${d}/index.html"
		[[ -f "${idx}" ]] || continue
		if grep -qF -- "${marker}" "${idx}" 2>/dev/null; then
			continue
		fi
		tmp="${idx}.tmp.$$"
		if ! {
			cat -- "${idx}"
			printf '\n%s\n<script src="/overlay.js"></script>\n' "${marker}"
		} >"${tmp}"; then
			warn "cannot inject the time-travel overlay into ${idx}"
			rm -f -- "${tmp}"
			continue
		fi
		if ! mv -f -- "${tmp}" "${idx}"; then
			warn "cannot install the overlay-injected ${idx}"
			rm -f -- "${tmp}"
			continue
		fi
	done < <(list_render_dirs)
}

# generate_timeline: write <OUTPUT_DIR>/index.html, a small self-contained
# static page (embedded CSS, dark theme, no external assets, no JS) listing
# the published renders newest-first: human-readable date, save name, a link
# to the archived map view (/renders/<dir>/index.html), and a "latest" badge
# on the newest entry linking to /latest/. Written atomically (temp + mv);
# Caddy serves the OUTPUT_DIR root, so the links must be absolute. Idempotent
# and cheap — regenerated after every publish AND after every skip; a failure
# to write is a warning, never fatal.
generate_timeline() {
	local out="${OUTPUT_DIR}/index.html"

	# Only dirs matching the pinned <YYYYMMDD-HHMMSS>_<name> format are listed
	# (anything else under renders/ is not a render) — enumerated newest-first
	# below via the shared list_render_dirs helper (oldest-first).
	local -a dirs=()
	local d
	while IFS= read -r d; do
		dirs+=("${d}")
	done < <(tac < <(list_render_dirs))

	local count="${#dirs[@]}"
	local tmp="${out}.tmp.$$"
	if ! {
		cat <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Factorio map timeline</title>
<style>
	body { background: #16181d; color: #d7dae0; font-family: system-ui, sans-serif; max-width: 46rem; margin: 2rem auto; padding: 0 1rem; }
	h1 { font-size: 1.4rem; color: #f0b429; }
	.meta { color: #7f8790; font-size: 0.85rem; }
	ul { list-style: none; padding: 0; }
	li { padding: 0.55rem 0.75rem; border-bottom: 1px solid #2a2e35; }
	.date { color: #9aa3ad; font-variant-numeric: tabular-nums; }
	.badge { background: #f0b429; color: #16181d; font-size: 0.75rem; font-weight: 700; padding: 0.1rem 0.45rem; border-radius: 0.6rem; margin-right: 0.4rem; }
	.pinbadge { background: #2a6e4f; color: #d8f3e3; font-size: 0.75rem; font-weight: 700; padding: 0.1rem 0.45rem; border-radius: 0.6rem; margin-right: 0.4rem; }
	a { color: #4da3ff; text-decoration: none; }
	a:hover { text-decoration: underline; }
</style>
</head>
<body>
<h1>Factorio map timeline</h1>
EOF
		printf '<p class="meta">generated %s UTC &middot; %d render(s) &middot; newest first</p>\n' \
			"$(date -u '+%Y-%m-%d %H:%M:%S')" "${count}"
		printf '<ul>\n'
		local i base ts_raw save_name date_human esc_base esc_save esc_date
		for ((i = 0; i < count; i++)); do
			d="${dirs[${i}]}"
			base="${d##*/}"
			ts_raw="${base%%_*}"
			save_name="${base#*_}"
			date_human="${ts_raw:0:4}-${ts_raw:4:2}-${ts_raw:6:2} ${ts_raw:9:2}:${ts_raw:11:2}:${ts_raw:13:2} UTC"
			esc_base="$(html_escape "${base}")"
			esc_save="$(html_escape "${save_name}")"
			esc_date="$(html_escape "${date_human}")"
			printf '<li>'
			if (( i == 0 )); then
				printf '<a class="badge" href="/latest/">latest</a>'
			fi
			if [[ -f "${d}/pinned" ]]; then
				printf '<span class="pinbadge">pinned</span> '
			fi
			printf '<span class="date">%s</span> &mdash; %s &middot; <a href="/renders/%s/index.html">view map</a></li>\n' \
				"${esc_date}" "${esc_save}" "${esc_base}"
		done
		printf '</ul>\n</body>\n</html>\n'
	} >"${tmp}"; then
		warn "cannot write the timeline page ${tmp} — leaving the previous ${out} in place"
		rm -f -- "${tmp}"
		return 0
	fi
	if ! mv -f -- "${tmp}" "${out}"; then
		warn "cannot install the timeline page at ${out} — leaving the previous one in place"
		rm -f -- "${tmp}"
		return 0
	fi
	info "timeline: wrote ${out} (${count} render(s))"
}

# validate_render_dir_name <name>: a published render dir name must match
# the pinned <YYYYMMDD-HHMMSS>_<save> format — this is what the pin/unpin
# CLI accepts and what keeps the marker write inside renders/.
validate_render_dir_name() {
	[[ "${1:-}" =~ ^[0-9]{8}-[0-9]{6}_.+ ]]
}

# cmd_pin <dir-name>: mark a published render as pinned ("do not delete").
# Pinned renders are excluded from retention rotation AND do not consume a
# RETENTION_COUNT slot (see prune_renders). The pin is a marker file inside
# the render dir, so it survives timeline regeneration and travels with the
# render. Refreshes the timeline layer so the badge shows immediately.
cmd_pin() {
	local name="${1:-}"
	if ! validate_render_dir_name "${name}"; then
		err "usage: render.sh pin <YYYYMMDD-HHMMSS>_<save-name> (e.g. render.sh pin 20260915-192212_SOLO-k2se)"
		return 1
	fi
	local dir="${RENDERS_DIR}/${name}"
	if [[ ! -d "${dir}" ]]; then
		err "${dir}: no such render"
		return 1
	fi
	if ! touch -- "${dir}/pinned"; then
		err "cannot create ${dir}/pinned"
		return 1
	fi
	info "pinned ${name} — excluded from retention rotation (does not consume a slot)"
	update_timeline_layer
}

# cmd_unpin <dir-name>: remove the pin; the render is subject to retention
# rotation again.
cmd_unpin() {
	local name="${1:-}"
	if ! validate_render_dir_name "${name}"; then
		err "usage: render.sh unpin <YYYYMMDD-HHMMSS>_<save-name>"
		return 1
	fi
	local dir="${RENDERS_DIR}/${name}"
	if [[ ! -d "${dir}" ]]; then
		err "${dir}: no such render"
		return 1
	fi
	if ! rm -f -- "${dir}/pinned"; then
		err "cannot remove ${dir}/pinned"
		return 1
	fi
	info "unpinned ${name} — subject to retention rotation again"
	update_timeline_layer
}

# cmd_pins: list all currently pinned render dir names.
cmd_pins() {
	local d
	while IFS= read -r d; do
		if [[ -f "${d}/pinned" ]]; then
			printf '%s\n' "${d##*/}"
		fi
	done < <(list_render_dirs)
}

# update_timeline_layer: the single entry point for everything that must
# track the state of renders/ on EVERY run — the timeline homepage, the
# timeline.json manifest, the overlay script and the (retrofitting) overlay
# injection into all retained render dirs. Called from cmd_render's success
# AND skip arms: a skip still refreshes the layer (cheap, idempotent, never
# fatal), which is also how renders published before the overlay existed
# gain it on the next run.
update_timeline_layer() {
	generate_timeline
	write_timeline_json
	ensure_overlay_js
	inject_time_overlay
}

# render_cleanup: EXIT trap for the render arm — the staging tree never
# survives a run, success or failure. The lock fd releases automatically
# when the process exits.
render_cleanup() {
	rm -rf -- "${STAGING_ROOT}"
}

cmd_render() {
	load_config

	local started_at
	started_at="$(date +%s)"

	preflight

	# Resolve the instance's saves/mods dirs first: detect_version's alias
	# arm (via resolve_edition) already reads the resolved mods dir, and
	# select_save/prepare_sandbox consume the globals below.
	resolve_instance_dirs

	detect_version
	info "render: Factorio version ${FACTORIO_VERSION_RESOLVED} (source: ${FACTORIO_VERSION_SOURCE})"

	local edition
	if [[ -n "${_FM_EDITION_RESOLVED}" ]]; then
		# detect_version's alias arm already resolved it (see the global's
		# comment) — reuse instead of re-parsing the mod list and re-logging.
		edition="${_FM_EDITION_RESOLVED}"
	else
		edition="$(resolve_edition)"
	fi

	local client_bin
	client_bin="$(ensure_factorio "${FACTORIO_VERSION_RESOLVED}" "${edition}")"
	info "render: Factorio client: ${client_bin}"

	# Staging removal on exit (success or failure). Arming it here is safe:
	# ensure_factorio ran inside a command-substitution subshell, so its own
	# EXIT trap (curl config/tmp cleanup) fired and vanished together with
	# that subshell — it never touched this parent shell's trap chain.
	trap render_cleanup EXIT

	local save_zip
	save_zip="$(select_save)"
	check_save_integrity "${save_zip}"

	local save_base
	save_base="$(basename -- "${save_zip}")"
	save_base="${save_base%.zip}"
	info "render: selected save '${save_base}'"

	# --- unchanged-save skip ("time travel" guard) --------------------------
	# The server stops at 0 players and saves when the last player leaves
	# (autosaves happen only while players are online), so a save that hashes
	# identically to the currently published one means nothing new to render.
	# The check runs AFTER the integrity check and BEFORE prepare_sandbox, so
	# a skip exits before the ~2 GB sandbox client copy. The snapshot copy is
	# byte-identical to the staged save, so hashing the staged file here is
	# equivalent. Missing/unparsable previous metadata (renders made before
	# this feature) counts as changed: one re-render, then the skip works.
	local save_sha
	save_sha="$(sha256sum -- "${save_zip}" 2>/dev/null | cut -d' ' -f1 || true)"
	if [[ -z "${save_sha}" ]]; then
		warn "cannot hash ${save_zip} (sha256sum failed) — rendering without the unchanged-save skip"
	fi
	_FM_SAVE_SHA256="${save_sha}"
	_FM_EDITION="${edition}"

	local prev_dir=''
	prev_dir="$(readlink -f -- "${OUTPUT_DIR}/latest" 2>/dev/null || true)"
	local prev_sha=''
	local prev_save=''
	if [[ -n "${prev_dir}" && -d "${prev_dir}" ]]; then
		prev_sha="$(render_meta_read "${prev_dir}")"
		prev_save="$(sed -n 's/^save=\(.*\)$/\1/p' "${prev_dir}/render-meta.txt" 2>/dev/null | head -n 1 || true)"
	fi
	if [[ -n "${save_sha}" && "${save_sha}" == "${prev_sha}" && -n "${prev_save}" && "${prev_save}" == "${save_base}" ]]; then
		# Humanize the previous render's timestamp for the log line; keep the
		# raw dir name as fallback for anything unparseable.
		local prev_ts prev_ts_h=''
		prev_ts="$(basename -- "${prev_dir}")"
		prev_ts="${prev_ts%%_*}"
		if [[ "${prev_ts}" =~ ^[0-9]{8}-[0-9]{6}$ ]]; then
			prev_ts_h="${prev_ts:0:4}-${prev_ts:4:2}-${prev_ts:6:2} ${prev_ts:9:2}:${prev_ts:11:2}:${prev_ts:13:2} UTC"
		else
			prev_ts_h="${prev_ts}"
		fi
		info "save unchanged since last render (${prev_ts_h}) — skipping (nothing to time-travel to)"
		# Timeline layer for consistency (cheap); clean exit 0 — systemd oneshot
		# must show success, and this skip is a success by design.
		update_timeline_layer
		exit 0
	fi

	prepare_sandbox "${save_zip}" "${client_bin}"

	# Render with the SANDBOX copy of the client (not the cache binary):
	# Factorio's portable-install write dir follows the binary location, and
	# it must be the sandbox root mapshot polls (see run_render).
	local render_bin="${SANDBOX_DATADIR}/bin/x64/factorio"

	local rc=0
	run_render "${save_base}" "${render_bin}" || rc=$?
	if (( rc != 0 )); then
		dump_factorio_diagnostics
		err "mapshot render failed (exit ${rc}) — check the mapshot/factorio log output above"
		return 1
	fi

	local render_dir
	if ! render_dir="$(locate_render_output "${save_base}")"; then
		err "render output not found (expected ${SANDBOX_DATADIR}/script-output/mapshot/${save_base}/index.html) — check the mapshot log output above"
		return 1
	fi
	info "render: output located at ${render_dir}"

	# Success path: refresh the client-cache GC (the client dir was touched
	# on cache hit) before publishing.
	prune_client_cache

	local publish_dir
	publish_dir="$(publish_render "${render_dir}" "${save_base}")"

	prune_renders

	# The timeline homepage lists the archive newest-first; the whole
	# timeline layer (manifest, overlay, injection included) is regenerated
	# after every publish (idempotent, cheap) so it always matches renders/.
	update_timeline_layer

	local duration
	duration=$(( $(date +%s) - started_at ))
	info "render: DONE in ${duration}s"
	info "render: published ${publish_dir}"
	info "render: latest -> ${OUTPUT_DIR}/latest -> $(readlink -- "${OUTPUT_DIR}/latest")"
}

main() {
	local cmd="${1:-check}"
	case "${cmd}" in
		check)
			if (( $# > 0 )); then shift; fi
			cmd_check "$@"
			;;
		render)
			if (( $# > 0 )); then shift; fi
			cmd_render "$@"
			;;
		pin | unpin | pins)
			local sub="${cmd}"
			if (( $# > 0 )); then shift; fi
			"cmd_${sub}" "$@"
			;;
		-h | --help)
			usage
			;;
		*)
			# Passthrough arm: forward everything verbatim to the mapshot
			# binary, e.g. `render.sh version` (mapshot has no --version
			# flag; its subcommand is `version`).
			exec mapshot "$@"
			;;
	esac
}

main "$@"
