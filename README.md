# Factorio map viewer sidecar (mapshot + AMP + Caddy)

A self-hosted, automatically-updating **public map viewer** for a Factorio
server (built for Space Exploration + Krastorio 2 on a CubeCoders AMP
instance). A [mapshot](https://github.com/Linkk93/mapshot) render container
(a fork of [Palats/mapshot](https://github.com/Palats/mapshot) carrying a
one-line Factorio 2.1 compatibility fix — see *How updates work*) runs
alongside the live game server as a *sidecar*: every night (or on
demand) it snapshots the newest save, renders the explored map with software
OpenGL, and publishes the result as static files that Caddy serves.

Three guarantees, plainly:

1. **The game server keeps running during renders.** The AMP instance is
   mounted read-only and the save is *copied* into a sandbox before
   rendering — nothing the render does can touch the live server.
2. **Renders publish atomically.** The public `latest` symlink is swapped
   with a single `rename(2)`; readers never see a missing or half-published
   map, and a failed render leaves the previous one public.
3. **The result is a public static page.** `https://your-map-host/` shows a
   timeline of all published renders (newest first), each one viewable — an
   addressable "time travel" history of the map.

## How it works

```
          systemd timer (04:30 nightly, Persistent=true)
                          │
                          ▼
   factorio-mapshot.service ──▶  docker compose run --rm mapshot render
                          │
                          ▼
  ┌── mapshot container ─────────────────────────┐        ┌── AMP instance ──┐
  │ render.sh                                    │  read- │                  │
  │  1. detect Factorio version ◀────────────────────────── │ saves/  mods/    │
  │  2. fetch full Factorio client (cached vol)  │  only  │ factorio/        │
  │  3. skip (exit 0) if save unchanged since    │        └──────────────────┘
  │     last render (sha256 in render-meta.txt)  │    (live server keeps running;
  │  4. build sandbox: client copy + save + mods │     render is nice/ionice'd)
  │  5. render: Xvfb + Mesa llvmpipe + mapshot   │
  │  6. publish: rename + atomic symlink swap    │
  │  7. prune retention + regenerate timeline    │
  └──────────────────┬───────────────────────────┘
                     ▼
      /srv/factorio-maps/                    (OUTPUT_DIR_HOST)
        ├── index.html                       (timeline homepage)
        ├── renders/20260913-043000_<save>/  (RETENTION_COUNT kept)
        │     └── render-meta.txt            (save name + sha256 → skip)
        └── latest ──▶ renders/20260913-043000_<save>
                    │
                    ▼
     Caddy (public): https://map.example.com/          → timeline index.html
                     https://map.example.com/latest/   → newest map
                     https://map.example.com/renders/… → archived renders
```

Output layout: timestamped render dirs (`UTC`, lexicographic = chronological)
under `renders/`, a `latest` symlink, and a generated `index.html` timeline at
the root. Public: `/` (timeline), `/latest/` (newest map) and
`/renders/<ts>_<save>/` (archive) — `.staging/` and the lock file are hidden
from the file server.

## Prerequisites

- **Ubuntu** server (systemd + bash).
- **Docker Engine + Compose v2 plugin** (`docker compose version` works).
- **Caddy** as your existing web server (only needed for the public page —
  renders work without it).
- **factorio.com credentials** (username + API token from your
  [profile page](https://factorio.com/profile)) — required once per Factorio
  version to download the full client (~1–2 GB).
- **Disk**: enough for a Factorio client per version, plus multi-GB per
  render for a megabase. See [Disk management](#disk-management).

## Server setup

Everything below happens **on the server**, after cloning. The repo is
developed off-server; the server is where docker runs.

Quick-start (details in the sections that follow):

```bash
git clone <your-repo-url> /opt/factorio-server-maps
cd /opt/factorio-server-maps
cp .env.example .env && chmod 600 .env
nano .env                                  # fill the two required bits (below)
./scripts/validate.sh                      # must exit 0
docker compose run --rm mapshot render     # first render (manual)
# then: nightly timer + Caddy (below)
```

> If you clone somewhere other than `/opt/factorio-server-maps`, adjust the
> two paths inside `systemd/factorio-mapshot.service` (marked `ADJUST`) and
> the Caddy root path (marked in `Caddyfile.mapshot`).

### 1. Find the AMP instance name

`.env` needs the **instance directory name** under the AMP data root. Find it
any of these ways:

- AMP web UI → **Instances** → the instance name;
- `docker ps` (AMP containerized instances are named after the instance);
- `sudo ls /home/amp/.ampdata/instances/` (the default AMP data root).

If AMP stores its data elsewhere on the host (e.g. a bind mount into the AMP
container), point `AMP_DATA_ROOT` at that host path — check with
`docker inspect <amp-container> | grep -A3 Mounts`.

### 2. Create and edit `.env`

```bash
cp .env.example .env && chmod 600 .env
```

Required:

| Variable | Why |
|---|---|
| `AMP_INSTANCE_NAME` | instance dir under `AMP_DATA_ROOT`; mounted read-only at `/instance` |
| `FACTORIO_USERNAME` / `FACTORIO_TOKEN` | factorio.com login; only used when a client download is needed |

The rest work out of the box; the most interesting knobs:

| Variable | Default | Meaning |
|---|---|---|
| `OUTPUT_DIR_HOST` | `/srv/factorio-maps` | host dir Caddy serves |
| `FACTORIO_VERSION` | *(auto)* | empty = auto-detect from the instance; a concrete version (e.g. `2.0.28`); or the aliases `experimental`/`stable`, resolved via the factorio.com latest-releases API on every run |
| `FACTORIO_EDITION` | *(auto)* | `alpha` (no Space Age) or `expansion` (with); empty auto-detects from the instance's enabled `space-age` mod |
| `SAVE_NAME` | *(newest)* | pin a specific save instead of the newest |
| `INSTANCE_SAVES_DIR` / `INSTANCE_MODS_DIR` | *(auto)* | in-container path overrides for the instance's `saves/` and `mods/` dirs; empty = auto-discovered (AMP nests them at `<instance>/factorio/server/...` in newer layouts; `mods/` is found via its `mod-list.json`) |
| `RENDER_TIMEOUT_SECS` | `21600` (6 h) | hard cap around the render |
| `RETENTION_COUNT` | `10` | old renders kept (timeline depth ≈ kept × render frequency) |
| `MIN_FREE_GB` | `10` | pre-flight disk floor; render is skipped below it |

Every variable is documented in `.env.example` — that file is the single
source of truth for knobs.

### 3. Validate

```bash
./scripts/validate.sh
```

Checks docker + compose v2, lints `render.sh` with shellcheck (skipped with
a warning if shellcheck is not installed), and runs
`docker compose config -q` against **your** `.env` (this catches an
empty required variable). Warnings about missing instance/output dirs are
expected if you run it somewhere the paths don't exist — hard failures stop
the script.

### 4. First render (manual)

```bash
docker compose run --rm mapshot render
```

The first run builds the image, downloads the matching full Factorio client
(~1–2 GB, needs valid credentials), snapshots the save and renders. On a
SE+K2 megabase expect **hours** and **multi-GB** output — see
[Tuning](#tuning-for-space-exploration--krastorio-2). The game server is
untouched and keeps running throughout.

When it finishes:

- `/srv/factorio-maps/` holds the new render plus the regenerated timeline:
  `latest/index.html` is the newest map, `index.html` the timeline homepage
  linking to every archived render (public once Caddy points at it, below);
- `docker compose run --rm mapshot check` prints the resolved configuration
  any time.

### 5. Enable the nightly timer

```bash
sudo cp systemd/factorio-mapshot.service systemd/factorio-mapshot.timer /etc/systemd/system/
# (adjust the repo path in the .service file if you did not clone to
#  /opt/factorio-server-maps — both marked with ADJUST)
sudo systemctl daemon-reload
sudo systemctl enable --now factorio-mapshot.timer
systemctl list-timers factorio-mapshot.timer
```

- Trigger a render immediately: `sudo systemctl start factorio-mapshot`
- Follow logs: `journalctl -u factorio-mapshot -f`
- Schedule: nightly **04:30** (+15 min jitter) — this `OnCalendar` in the
  timer file is the **one knob outside `.env`**.
- `Persistent=true`: a schedule missed while the server was down runs once
  at boot (after docker is up, via the unit's `After=`/`Wants=`).
- `TimeoutStartSec=12h` on the service must stay **≥ `RENDER_TIMEOUT_SECS`
  (default 6 h) plus download/extract time**. If you raise
  `RENDER_TIMEOUT_SECS` in `.env` toward ~11 h, raise `TimeoutStartSec` to
  match.
- **Stopping mid-render**: `systemctl stop` sends SIGTERM, which the
  attached `docker compose run` forwards — but bash as the container's
  PID 1 ignores SIGTERM, so nothing happens until docker's 10 s grace
  period expires and it SIGKILLs the container. That kill is abrupt:
  render.sh's EXIT cleanup may not run (stale `/output/.staging` is wiped
  by the next run). **Verify once after install, mandatory:** start a
  render, `systemctl stop factorio-mapshot`, and confirm `docker ps` shows
  no mapshot container a few seconds later.
- Overlap is impossible by construction: a timer fire while a manual render
  runs loses the `flock` inside render.sh and exits 0 immediately.

### 6. Serve it with Caddy

`Caddyfile.mapshot` defines an importable snippet; comments in that file show
the full integration. Short version:

```caddy
import Caddyfile.mapshot        # top of your /etc/caddy/Caddyfile

map.example.com {
	import factorio_maps
}
```

```bash
sudo cp Caddyfile.mapshot /etc/caddy/
caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

- The snippet roots the site at `<OUTPUT_DIR_HOST>` — adjust the path in the
  snippet if you changed `OUTPUT_DIR_HOST`.
- `/` serves the generated timeline homepage (`index.html`, rewritten after
  every render or skip); `/latest/` is the newest map;
  `/renders/<timestamp>_<save>/index.html` are the archived views — the
  time-travel history, `RETENTION_COUNT` entries deep.
- **In-map time-travel overlay**: every render page carries a small date
  switcher (bottom-left, ‹ dropdown ›) fed by `timeline.json`. It lists the
  retained renders of that save only, and switching jumps to the selected
  date **keeping the current view** — position, zoom, surface and layer
  toggles live in the URL and are forwarded verbatim. Renders published
  before the overlay existed are retrofitted on the next run (injection is
  idempotent and also happens on skips); a render dir served without the
  output root (e.g. tarred out) simply shows no overlay.
- Caching: tile URLs (`d-<hash>/`) are immutable (1 year); everything else is
  `no-cache`, so browsers revalidate — cheap `304`s, since `latest/` content
  changes with each render. JPEG tiles are excluded from compression (they
  are already compressed).
- The file server hides `.staging/` and `.render.lock`; nothing else under
  the output dir is sensitive (`render-meta.txt` per render is just save
  name/hash metadata).
- No reload is needed between renders — the atomic symlink swap and the
  timeline rewrite are picked up per request.

## Tuning for Space Exploration + Krastorio 2

SE+K2 megabases are the worst case: **the first render can take hours and
produce multiple GB**. The committed defaults are the recommended starting
point — render that first, look at it, then raise knobs incrementally:

| Knob | Default (start here) | To see more |
|---|---|---|
| `MAPSHOT_AREA` | `entities` | `all` (whole world — big) |
| `MAPSHOT_TILEMIN` | `64` | `32` / `16` (more zoom detail, much bigger output) |
| `MAPSHOT_JPGQUALITY` | `85` | `90` (larger files) |
| `MAPSHOT_SURFACE` | `_all_` (all SE surfaces) | `nauvis` for quick single-planet tests |

Other levers:

- **CPU contention with the game server**: the render already runs
  `nice -n 19 ionice -c 3` inside the container (systemd `Nice=` cannot reach
  container processes — do not add it to the unit). For a harder cap set
  `LP_NUM_THREADS` in `.env` (llvmpipe threads) and/or uncomment the
  `# cpus: "8"` line in `docker-compose.yml`.
- **Timeouts**: `RENDER_TIMEOUT_SECS` caps a runaway render; remember the
  systemd `TimeoutStartSec` relationship (above).
- **GL**: `LIBGL_ALWAYS_SOFTWARE=1` (Mesa llvmpipe) is already set in the
  image; it can also be set in `.env` (env passthrough). See
  [Troubleshooting](#troubleshooting) if GL/Xvfb still fails.

## Disk management

Check `df -h` before the first render; prefer a dedicated volume for
`OUTPUT_DIR_HOST` (and docker's data root) so a full render can never fill
the OS partition of the game server.

- `MIN_FREE_GB` (default 10) is a pre-flight floor on both `/output` and
  `/cache` — a render below it is skipped with a clear log line, not a
  half-filled disk. On `/output` the guard adds ~3 GB of headroom because
  the render sandbox holds a full copy of the Factorio client (~2.5 GB)
  next to the render output. Publishing is a same-filesystem rename, so
  the render itself never temporarily occupies double space.
- `RETENTION_COUNT` (default 10): old `renders/<ts>_<save>/` dirs are pruned
  after each successful render; the pruned history is what bounds the
  timeline depth on the public page.
- `CLIENT_CACHE_COUNT` (default 2): version-keyed Factorio clients in the
  `factorio-clients` docker volume, pruned newest-by-mtime after successful
  renders. To reclaim their space manually:
  `docker volume rm factorio-server-maps_factorio-clients` (name from
  `docker volume ls`; do it between renders).
- `/output/.staging/` is wiped at the start and end of every run.

## Security notes

- **`.env` contains your factorio.com token.** It is gitignored; keep it
  `chmod 600`. The Factorio API token is **account-scoped** (there is no
  download-only scope) — if it ever leaks, rotate it on your
  [factorio.com profile](https://factorio.com/profile) and update `.env`.
- At runtime, credentials exist only in the container env and in a **curl
  config written to a tmpfs** (`/run/factorio.curlcfg`, mode 0600) that is
  deleted immediately after the download. factorio.com's download endpoint
  rejects HTTP basic auth and requires the credentials as username/token
  query parameters, so render.sh puts the full authenticated URL into that
  0600 file, which curl reads via `-K` — the token never appears in argv,
  command lines or logs, and the authenticated URL itself is never logged
  (only the redacted path without the query string).
- Anyone with docker access on the host can read container env vars
  (`docker inspect`) — acceptable on a single-admin host.
- The **full AMP instance directory is mounted read-only**. The kernel blocks
  every write, including shared mmap — the live server cannot be corrupted.
  Note the flip side: AMP-internal config files become *readable* by the
  (root) render container. Single-admin host assumption.
- Output files are written by the container's root with world-readable
  defaults, which is exactly what the `caddy` user needs. Only loosen
  further if you harden umasks/ACLs and Caddy starts getting 403s.

## How updates work

- **New Factorio version** (via AMP): detected automatically from the
  instance's own `data/base/info.json` on the next render. The matching full
  client is downloaded **once** (needs valid credentials in `.env`), cached
  in the volume, and old clients are garbage-collected to
  `CLIENT_CACHE_COUNT`. No manual action.
- **A save newer than the binary** cannot happen: the render binary version
  is always ≥ the detected instance version.
- **mapshot updates** are pinned (`ARG MAPSHOT_VERSION` in the
  `Dockerfile`): bump the version, then run `docker compose build`
  explicitly — `docker compose run` only builds when the image is missing.
  The pin currently points at the **Linkk93 fork** (`0.0.28-2.1`), not
  upstream: upstream 0.0.28 declares `factorio_version "2.0"` in the mod's
  `info.json`, and Factorio 2.1 refuses to load such mods — the fork bumps
  that one line to `"2.1"` with no other changes. When upstream ships a
  2.1-capable release, switch the download URL in the `Dockerfile` back to
  `Palats/mapshot` and bump the pin.

## Troubleshooting

Run `docker compose run --rm mapshot check` first — it prints the resolved
configuration and validates mounts/tools inside the container.

| Symptom | Cause / fix |
|---|---|
| GL/Xvfb errors (`could not initialize GLX`, Xvfb crash) | Software GL is already forced (`LIBGL_ALWAYS_SOFTWARE=1`). Try a different `XVFB_SCREEN` depth (e.g. `1920x1080x16`). Debug with `docker compose run --rm --entrypoint xvfb-run mapshot glxinfo -B` (glxinfo needs the virtual display, hence xvfb-run; expect a llvmpipe renderer). |
| `cannot determine Factorio version — set FACTORIO_VERSION in .env` | The instance layout hid its version. Set `FACTORIO_VERSION` (e.g. `2.0.28`) in `.env`. |
| Download fails / wrong version | Check credentials — but note the exact version may simply no longer be published (factorio.com prunes obsolete/experimental builds). render.sh then retries with `latest` automatically; if even that fallback is older than the save's version, update the AMP instance or set `FACTORIO_VERSION` to a downloadable version. A 2.1 save cannot render in a 2.0 binary. |
| `FACTORIO_VERSION=experimental`/`stable` downloaded a new client | Expected: the aliases re-resolve on every run via the factorio.com latest-releases API, so a new upstream build triggers one fresh download automatically; the superseded client dir is pruned by `CLIENT_CACHE_COUNT`. Pin a concrete version to freeze the client. |
| `no saves directory found under /instance` | AMP nests server data at `<instance>/factorio/server/saves/` in newer layouts; render.sh auto-discovers all known layouts. If discovery still fails, set `INSTANCE_SAVES_DIR` (and `INSTANCE_MODS_DIR`) in `.env` to the in-container path under `/instance`. |
| Save-stability error (`still being written ... 120s`) | The newest autosave is <120 s old (live server may be mid-write). Retry, or pin `SAVE_NAME` in `.env`. |
| Disk-guard error (`only XGB free ... MIN_FREE_GB`) | Free space on the named mount or lower `MIN_FREE_GB` deliberately. Check `df -h`. |
| Caddy serves 403/404 | Root path mismatch: snippet root must be `<OUTPUT_DIR_HOST>` (not `/latest` — the timeline and archive live at the root); check `OUTPUT_DIR_HOST` in `.env`. |
| `.env` changes have no effect | Compose reads `.env` from the project directory — run compose commands from the repo root. |
| Instance dir warning in validate.sh | AMP data root differs on your host — see step 1 of Server setup. |
