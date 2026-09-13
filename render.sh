#!/usr/bin/env bash
#
# render.sh — entrypoint for the Factorio mapshot render sidecar.
#
# Subcommands:
#   check          (default) validate config, print the resolved-value table,
#                  check container mounts and tool availability
#   render         run the mapshot render pipeline: lock + preflight guards,
#                  save selection, sandbox assembly, mapshot invocation,
#                  atomic publish + retention
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
# /output contract (the docker compose bind of OUTPUT_DIR_HOST): renders/,
# .staging/ scratch, .render.lock and the latest symlink all live here.
# Co-locating staging and final output on one filesystem is what makes
# publication a same-filesystem rename. Honors the environment like
# INSTANCE_DIR/CACHE_DIR so host-side tests can point it at a fixture tree.
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
STAGING_ROOT="${OUTPUT_DIR}/.staging"
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
	FACTORIO_EDITION="${FACTORIO_EDITION:-alpha}"
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
	RETENTION_COUNT="${RETENTION_COUNT:-3}"
	CLIENT_CACHE_COUNT="${CLIENT_CACHE_COUNT:-2}"
	MIN_FREE_GB="${MIN_FREE_GB:-10}"
	LP_NUM_THREADS="${LP_NUM_THREADS:-}"
	XVFB_SCREEN="${XVFB_SCREEN:-1920x1080x24}"
	RENDER_TIMEOUT_SECS="${RENDER_TIMEOUT_SECS:-21600}"
}

# instance_info_json: print the path of the instance's Factorio info.json.
# Canonical AMP layout first, then a bounded find fallback for AMP-version-
# dependent layouts. Pure file read — no execution, no network. INSTANCE_DIR
# is honored so tests can point this at a fixture tree.
instance_info_json() {
	local canonical="${INSTANCE_DIR}/factorio/data/base/info.json"
	if [[ -f "${canonical}" ]]; then
		printf '%s\n' "${canonical}"
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

# detect_version: resolve the Factorio version into the globals
# FACTORIO_VERSION_RESOLVED / FACTORIO_VERSION_SOURCE.
# Order: (a) FACTORIO_VERSION override → (b) the instance's own info.json
# (pure file read — preferred over executing a host-built binary that may
# not run under the container's glibc) → (c) any bin/x64/factorio under the
# instance via --version (last resort). Returns 1 with an actionable error
# when nothing works. Detection never touches the network.
detect_version() {
	FACTORIO_VERSION_RESOLVED=''
	FACTORIO_VERSION_SOURCE=''

	if [[ -n "${FACTORIO_VERSION}" ]]; then
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
	printf '%-24s %s\n' 'FACTORIO_EDITION' "${FACTORIO_EDITION}"
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
	printf '%-24s %s\n' 'CLIENT_CACHE_COUNT' "${CLIENT_CACHE_COUNT}"
	printf '%-24s %s\n' 'MIN_FREE_GB' "${MIN_FREE_GB}"
	printf '%-24s %s\n' 'LP_NUM_THREADS' "${LP_NUM_THREADS:-<empty: llvmpipe default>}"
	printf '%-24s %s\n' 'XVFB_SCREEN' "${XVFB_SCREEN}"
	printf '%-24s %s\n' 'RENDER_TIMEOUT_SECS' "${RENDER_TIMEOUT_SECS}"

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
	printf '\n== mounts ==\n'
	if [[ -d "${INSTANCE_DIR}" ]]; then
		if [[ -d "${INSTANCE_DIR}/saves" ]]; then
			info "${INSTANCE_DIR}/saves: OK"
		else
			err "${INSTANCE_DIR}/saves: missing — is AMP_INSTANCE_NAME correct?"
			failures=1
		fi
		if [[ -f "${INSTANCE_DIR}/mods/mod-list.json" ]]; then
			info "${INSTANCE_DIR}/mods/mod-list.json: OK"
		else
			warn "${INSTANCE_DIR}/mods/mod-list.json: not found (the render requires it; fine if this instance is vanilla-configuration-free)"
		fi
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

# _FM_TMPDIR / _FM_NETRC: the temp paths of a running ensure_factorio
# download, kept as GLOBALS on purpose. ensure_factorio runs inside a
# command-substitution subshell; by the time its EXIT trap fires, the
# function has returned and its locals are destroyed — a trap referencing
# them would hit set -u unbound-variable errors. The trap below therefore
# reads these globals instead.
_FM_TMPDIR=''
_FM_NETRC=''

# factorio_dl_cleanup: EXIT-trap backstop for ensure_factorio's download
# arm — wipes the credentials netrc and the partial download tree on any
# abort. Runs inside the same subshell, so it only ever touches these
# globals; the parent shell's trap chain is untouched.
factorio_dl_cleanup() {
	trap - EXIT
	if [[ -n "${_FM_NETRC}" ]]; then
		rm -f -- "${_FM_NETRC}"
	fi
	if [[ -n "${_FM_TMPDIR}" ]]; then
		rm -rf -- "${_FM_TMPDIR}"
	fi
}

# ensure_factorio <version> <edition>: print (stdout) the path of a working
# full Factorio client binary; all diagnostics go to stderr so the stdout
# contract survives `$( ... )` capture. Cache hit: <CACHE_DIR>/factorio/
# <version>-<edition>/bin/x64/factorio whose --version matches — no network.
# Miss: download https://factorio.com/get-download/<version>/<edition>/linux64
# using a 0600 netrc under /run (credentials never appear in argv or logs),
# extract, verify (--version >= <version> via ver_ge), atomically rename into
# place. Cache GC (prune_client_cache) runs once per render, on cmd_render's
# success path. Returns 1 on failure; the netrc and temp tree are wiped by
# the EXIT trap (factorio_dl_cleanup, via the globals above) on any abort.
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

	local netrc='/run/factorio.netrc'
	# Publish the temp paths into the globals the EXIT trap cleans (see
	# factorio_dl_cleanup above for why locals cannot be used here).
	_FM_TMPDIR="${tmp_dir}"
	_FM_NETRC="${netrc}"
	# Backstop: on any abort (set -e) or subshell exit, wipe the temp tree and
	# the netrc — credentials and partial downloads must never linger.
	trap factorio_dl_cleanup EXIT

	# netrc: write to a 0600 temp file, then rename into place, so the
	# credentials are never readable by anyone else, not even briefly.
	local netrc_tmp
	if ! netrc_tmp="$(mktemp /run/factorio.netrc.XXXXXX)"; then
		err 'cannot create a netrc temp file under /run (tmpfs)'
		return 1
	fi
	if ! { printf 'machine factorio.com login %s password %s\n' "${FACTORIO_USERNAME}" "${FACTORIO_TOKEN}" >"${netrc_tmp}" \
		&& chmod 0600 "${netrc_tmp}" && mv -f -- "${netrc_tmp}" "${netrc}"; } then
		rm -f -- "${netrc_tmp}"
		err 'cannot install the factorio.com netrc'
		return 1
	fi

	local url="https://factorio.com/get-download/${version}/${edition}/linux64"
	info "downloading Factorio ${version} (${edition}) from ${url} (this can take a while)" >&2
	if ! curl -n --netrc-file "${netrc}" -fL -o "${tmp_dir}/factorio.tar.xz" "${url}"; then
		err "download failed: ${url} — check FACTORIO_USERNAME / FACTORIO_TOKEN and that version ${version} exists for edition '${edition}'"
		return 1
	fi
	rm -f -- "${_FM_NETRC}"   # credentials are no longer needed from here on
	_FM_NETRC=''

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
		err "downloaded client reports version '${got_ver:-<none>}' but >= ${version} is required — check FACTORIO_VERSION and FACTORIO_EDITION"
		return 1
	fi

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
#   /output/latest                 symlink -> renders/<ts>_<save>, atomic swap

# Newest auto-picked save must be at least this old (seconds) before it is
# trusted: a fresher mtime means the live server is probably still writing
# it. An explicit SAVE_NAME bypasses the pick (but is still zip-checked).
SAVE_STABILITY_SECS=120

# Extra free space demanded on /output beyond MIN_FREE_GB: the render sandbox
# now contains a full portable copy of the Factorio client (~2-2.5 GB) on top
# of the render output itself. Padded to 3 GB; documented in .env.example
# (MIN_FREE_GB) and the README (Disk management).
SANDBOX_CLIENT_RESERVE_GB=3

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
# logs to stderr. SAVE_NAME wins (exact file in /instance/saves, ".zip"
# appended when missing); otherwise the newest *.zip by mtime, ignoring
# *.tmp.zip (download/save temporaries). The auto pick is only accepted when
# the file is at least SAVE_STABILITY_SECS old — fail fast otherwise, the
# live server may still be writing it.
select_save() {
	local saves_dir="${INSTANCE_DIR}/saves"
	if [[ ! -d "${saves_dir}" ]]; then
		err "${saves_dir}: missing — is AMP_INSTANCE_NAME correct?" >&2
		return 1
	fi

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
		local newest=''
		newest="$(find "${saves_dir}" -maxdepth 1 -type f -name '*.zip' ! -name '*.tmp.zip' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n 1 | cut -d' ' -f2- || true)"
		if [[ -z "${newest}" ]]; then
			err "no *.zip save found in ${saves_dir}" >&2
			return 1
		fi
		local mtime now age
		mtime="$(stat -c %Y -- "${newest}")"
		now="$(date +%s)"
		age=$((now - mtime))
		if (( age < SAVE_STABILITY_SECS )); then
			err "newest save ${newest} appears to be still being written (${age}s old < ${SAVE_STABILITY_SECS}s stability window) — retry shortly or set SAVE_NAME" >&2
			return 1
		fi
		selected="${newest}"
		info "save selection: ${selected} (newest stable save, mtime ${age}s old)" >&2
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
	local mods_src="${INSTANCE_DIR}/mods"
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
# Prints the published directory on stdout.
publish_render() {
	local render_dir="${1:?usage: publish_render <render-dir> <save-base>}"
	local save_base="${2:?usage: publish_render <render-dir> <save-base>}"

	local ts publish_name
	ts="$(date -u +%Y%m%d-%H%M%S)"
	publish_name="${ts}_${save_base}"

	mkdir -p -- "${RENDERS_DIR}"
	mv -- "${render_dir}" "${RENDERS_DIR}/${publish_name}"

	rm -f -- "${OUTPUT_DIR}"/.latest.tmp.*
	local tmp_link="${OUTPUT_DIR}/.latest.tmp.$$"
	ln -s "renders/${publish_name}" "${tmp_link}"
	mv -Tf -- "${tmp_link}" "${OUTPUT_DIR}/latest"

	printf '%s\n' "${RENDERS_DIR}/${publish_name}"
}

# prune_renders: keep the newest RETENTION_COUNT dirs under renders/, delete
# the rest. Glob expansion is sorted lexicographically, which — with the
# pinned UTC timestamp format — equals chronological order, so oldest-first
# pruning is order-safe. nullglob keeps a missing renders/ dir from pruning
# garbage; the dir `latest` points at is skipped defensively, so the symlink
# can never dangle mid-prune.
prune_renders() {
	local keep="${RETENTION_COUNT}"
	if [[ ! "${keep}" =~ ^[0-9]+$ ]]; then
		warn "RETENTION_COUNT='${keep}' is not a number — using default 3"
		keep=3
	fi
	if (( keep < 1 )); then
		warn 'RETENTION_COUNT=0 would delete the fresh render — using 1'
		keep=1
	fi

	local -a dirs=()
	local d
	shopt -s nullglob
	for d in "${RENDERS_DIR}"/*; do
		if [[ -d "${d}" ]]; then
			dirs+=("${d}")
		fi
	done
	shopt -u nullglob

	local total="${#dirs[@]}"
	if (( total <= keep )); then
		info "retention: ${total} render dir(s) present, nothing to prune (RETENTION_COUNT=${keep})"
		return 0
	fi

	local latest_target=''
	latest_target="$(readlink -f -- "${OUTPUT_DIR}/latest" 2>/dev/null || true)"

	local -a prune_dirs=()
	local i
	for ((i = 0; i < total - keep; i++)); do
		d="${dirs[${i}]}"
		if [[ -n "${latest_target}" && "${d}" -ef "${latest_target}" ]]; then
			warn "retention: ${d} is the current 'latest' target — skipping"
			continue
		fi
		prune_dirs+=("${d}")
	done
	if (( ${#prune_dirs[@]} == 0 )); then
		info 'retention: nothing to prune'
		return 0
	fi
	for d in "${prune_dirs[@]}"; do
		info "retention: pruning old render ${d}"
		rm -rf -- "${d}"
	done
	info "retention: pruned ${#prune_dirs[@]} old render dir(s), kept the newest (RETENTION_COUNT=${keep})"
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

	detect_version
	info "render: Factorio version ${FACTORIO_VERSION_RESOLVED} (source: ${FACTORIO_VERSION_SOURCE})"

	local client_bin
	client_bin="$(ensure_factorio "${FACTORIO_VERSION_RESOLVED}" "${FACTORIO_EDITION}")"
	info "render: Factorio client: ${client_bin}"

	# Staging removal on exit (success or failure). Arming it here is safe:
	# ensure_factorio ran inside a command-substitution subshell, so its own
	# EXIT trap (netrc/tmp cleanup) fired and vanished together with that
	# subshell — it never touched this parent shell's trap chain.
	trap render_cleanup EXIT

	local save_zip
	save_zip="$(select_save)"
	check_save_integrity "${save_zip}"

	local save_base
	save_base="$(basename -- "${save_zip}")"
	save_base="${save_base%.zip}"
	info "render: selected save '${save_base}'"

	prepare_sandbox "${save_zip}" "${client_bin}"

	# Render with the SANDBOX copy of the client (not the cache binary):
	# Factorio's portable-install write dir follows the binary location, and
	# it must be the sandbox root mapshot polls (see run_render).
	local render_bin="${SANDBOX_DATADIR}/bin/x64/factorio"

	local rc=0
	run_render "${save_base}" "${render_bin}" || rc=$?
	if (( rc != 0 )); then
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
