# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Table of contents

- [Instructions](#instructions)
- [What this is](#what-this-is)
- [Development commands](#development-commands)
- [Architecture](#architecture)
- [Testing](#testing)
- [Config file format](#config-file-format)
- [Deployment](#deployment)

---

## Instructions

- Répondre en français.
- Commentaires au-dessus du code (jamais en inline).
- Code, commentaires et descriptions de tests en anglais.
- Named arguments sur les appels complexes (ex: `Proxy.new(..., max_redirects: 5, index_ttl: 0, ...)`).
- Après chaque modification, toujours lancer : `mise dev:check` (équivalent à `mise dev:build && mise dev:ameba && mise dev:spec`).

## What this is

`apt-larder` is a Crystal HTTP caching proxy for APT package repositories. It sits between `apt` clients and upstream mirrors, caching `.deb` packages indefinitely and index files (e.g. `Packages`, `Release`) for a configurable TTL. It supports both transparent proxy mode (absolute URLs like `http://mirror/...`) and host-in-path mode (`/mirror.example.com/ubuntu/...`).

## Development commands

All tasks are run via `mise`:

```sh
mise dev:deps      # install deps (shards install)
mise dev:spec      # run tests
mise dev:ameba     # lint (static analysis)
mise dev:format    # format code (crystal tool format src/)
mise dev:build     # compile dev binary to bin/apt-larder
```

Run a single spec file:
```sh
crystal spec spec/some_spec.cr
```

Release builds (static binaries) use Docker:
```sh
mise release:static   # builds static Linux binaries via docker buildx bake
```

## Architecture

```
src/apt-larder.cr          Entry point: loads deps, config, starts CLI
src/apt_larder/
  cli.cr                   Admiral CLI — subcommands: server, info
  config.cr                YAML config (all fields documented below)
  admin_config.cr          AdminConfig — nested YAML config for the admin server
  server.cr                HTTP server lifecycle (start/stop, graceful shutdown, background loops)
  proxy.cr                 HTTP handler: resolves request → cache key + upstream URL, triggers fetch, serves file
  cache.cr                 Filesystem cache — atomic writes, TTL, SHA256 integrity sidecars, LRU eviction
  single_flight.cr         Concurrent deduplication — one upstream fetch per key; other fibers wait on a Channel
  connection_pool.cr       Per-host HTTP connection pool with stale-connection retry
  systemd.cr               systemd sd_notify integration (READY=1, STOPPING=1, watchdog, STATUS=)
  admin/
    server.cr              Admin HTTP server: routing + per-prefix auth middleware
    api.cr                 JSON REST API handlers (/api/*)
    handler.cr             Serves embedded HTML/CSS/JS assets (/*)
src/assets/admin/
  index.html / app.js / style.css   Web UI compiled into binary at build time
```

**Request flow:** `Proxy#handle` → `resolve` (maps request to cache key + upstream URL) → `ensure_cached` → `SingleFlight#run` → `download` (conditional GET with `If-Modified-Since`) → `serve` (streams from disk).

**Immutability heuristic:** `.deb`/`.udeb`/`.ddeb` files and paths containing `/pool/` or `/by-hash/` are treated as immutable (cached forever, SHA256-verified). Everything else uses `index_ttl` (minutes).

**Redirect handling:** `Proxy#fetch` follows HTTP 301/302/303/307/308 up to `max_redirects`, including http→https upgrades (Crystal's `HTTP::Client` handles TLS automatically).

**Integrity:** A `.sha256` sidecar is written alongside each cached file. Immutable files are verified on first serve per session; corrupt files are invalidated and re-downloaded automatically.

**Logging:** Supports `log_file: stdout` or a file path. Sends `SIGUSR1` to reopen the log file (log rotation), `SIGTERM` to stop gracefully (drains in-flight requests). Stats are logged hourly.

**Admin server:** When `admin.enabled: true`, a second HTTP server starts on `admin.port`. `/api/*` routes serve a JSON REST API (Bearer token auth, includes `/api/metrics` in Prometheus format); `/*` routes serve the embedded web UI (Basic auth). Both auth mechanisms are independent and optional.

## Testing

Uses [Spectator](https://gitlab.com/arctic-fox/spectator) (not Crystal's built-in `spec`). Test environment is detected via `crystal-env` — `Crystal.env.test?` is true when running specs.

Key spec files:
- `spec/proxy_spec.cr` — end-to-end proxy behaviour, stats, single-flight, revalidation
- `spec/cache_spec.cr` — cache operations, integrity, eviction
- `spec/admin_api_spec.cr` — REST API endpoints
- `spec/admin_auth_spec.cr` — Bearer and Basic auth middleware
- `spec/config_spec.cr` — YAML config parsing

## Config file format

Default: `apt-larder.yml` (override with `--config`/`-c`).

```yaml
cache_dir: ./cache
index_ttl: 5           # minutes before index files (Release, Packages) are revalidated
max_redirects: 5
connect_timeout: 10    # seconds
read_timeout: 30       # seconds
log_file: stdout       # or a file path
log_level: info        # trace, debug, info, warn, error, fatal, off
quiet: false           # when true, only MISS and ERR are logged
evict_after_days: 0    # delete files not accessed for N days (0 = disabled)
max_cache_size_gb: 0   # max cache size in GB — evicts LRU when exceeded (0 = disabled)
server_host: "0.0.0.0"
server_port: 3142
admin:
  enabled: false
  host: "127.0.0.1"   # loopback by default; use 0.0.0.0 inside Docker
  port: 8080
  api_token: ""        # Bearer token for /api/* — empty = no auth
  ui_user: ""          # HTTP Basic user for the web UI — empty = no auth
  ui_password: ""

# remaps:               # optional host remapping (bare host, host:port, or full URL)
#   deb.debian.org: my-mirror.internal
```

## Deployment

The Docker image (`docker-bake.hcl`) produces a distroless static binary image. The runtime image requires `ca-certificates` to be available for TLS certificate verification when following http→https redirects.

For the admin UI to be reachable from the host when running in Docker, set `admin.host: "0.0.0.0"` in the config and expose port 8080.
