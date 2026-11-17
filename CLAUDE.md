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
- **Toolchain épinglée : Crystal 1.20.3 (voir `mise.toml`).** Ne JAMAIS invoquer `crystal`/`shards` nu — le binaire système peut être une version différente et donner de faux positifs (une API absente en 1.20 peut compiler avec une version plus récente). Toujours passer par les tâches `mise` (`dev:build`, `dev:spec`, `dev:check`, …) ; elles utilisent la toolchain épinglée et transmettent les arguments positionnels (ex. `mise dev:spec spec/foo_spec.cr`). Ne pas utiliser d'API introduite après 1.20.

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

Run a single spec file (extra args are forwarded to the `dev:spec` task):
```sh
mise dev:spec spec/some_spec.cr
```

Release builds (static binaries) use Docker:
```sh
mise release:static   # builds static Linux binaries via docker buildx bake
```

## Architecture

```
src/apt-larder.cr          Entry point: loads deps, config, log setup, starts CLI
src/apt_larder/
  cli.cr                   Admiral CLI — subcommands: server, info, healthcheck, stats, cache (list/flush/invalidate), evict
  healthcheck.cr           Self-probe for Docker HEALTHCHECK — exits 0/1 on the proxy /_health
  config.cr                YAML config (all fields documented below), env overrides, validation
  admin_config.cr          AdminConfig — nested YAML config for the admin server
  helpers.cr               Immutability heuristic, CONNECT target parsing, local-address test, byte formatting
  log_backend.cr           Synchronous Log backend that survives a failing destination; reopen for rotation
  server.cr                HTTP server lifecycle (start/stop, graceful shutdown, background loops)
  proxy.cr                 HTTP handler: resolves request → cache key + upstream URL, target policy, triggers fetch, serves file; CONNECT tunnels
  cache.cr                 Filesystem cache — atomic writes, TTL, SHA256 integrity and validator sidecars, LRU eviction
  single_flight.cr         Concurrent deduplication — one upstream fetch per key; other fibers wait on a Channel
  connection_pool.cr       Per-host HTTP connection pool with stale-connection retry and idle sweep
  systemd.cr               systemd sd_notify integration (READY=1, STOPPING=1, watchdog, STATUS=)
  admin/
    server.cr              Admin HTTP server: routing + authentication
    api.cr                 JSON REST API handlers (/api/*)
    client.cr              HTTP client of the admin API, used by the CLI subcommands
    handler.cr             Serves embedded HTML/CSS/JS assets (/*)
src/assets/admin/
  index.html / app.js / style.css   Web UI compiled into binary at build time
  vendor/                           jQuery + DataTables, compiled in too (never loaded from a CDN)
```

**Request flow:** `Proxy#handle` → `resolve` (maps request to cache key + upstream URL) → `ensure_cached` → `SingleFlight#run` → `download` (conditional GET replaying the upstream `Last-Modified`/`ETag`) → `serve` (streams from disk). Keys the cache cannot hold as a file (sidecar names, temporary-file names, directory paths) skip the cache and go through `relay`.

**Target policy:** unless `allow_local_targets` is set, `Proxy#check_target!` refuses (403) any hop — first request or redirect, GET or CONNECT — whose host is or resolves to a loopback, unspecified or link-local address; remap targets are exempt (they come from the config). CONNECT is limited to `connect_ports` (default `[443]`). Specs that fetch from a fake upstream on 127.0.0.1 build their `Proxy` with `allow_local_targets: true`.

**Immutability heuristic:** `.deb`/`.udeb`/`.ddeb` files, paths containing `/by-hash/`, and files under `/pool/` (last segment with an extension) are treated as immutable (cached forever, SHA256-verified). Everything else uses `index_ttl` (minutes). A `/pool/` path without an extension is a directory index.

**Eviction:** sorts on the file mtime, which `Cache#mark_used` refreshes on a HIT of an immutable entry (at most once per hour per key) — never on an index file, whose mtime is its TTL clock. One pass at startup, then hourly.

**Stale on outage:** when revalidating an index fails because upstream is unreachable or answers 5xx, the cached copy is served (`Proxy#stale_or`); a 4xx is passed through.

**Redirect handling:** `Proxy#fetch` follows HTTP 301/302/303/307/308 up to `max_redirects`, including http→https upgrades (Crystal's `HTTP::Client` handles TLS automatically).

**Revalidation:** A `.validators` sidecar keeps the upstream `Last-Modified` and `ETag` of each index file; revalidation echoes `Last-Modified` verbatim in `If-Modified-Since`, and falls back to `If-None-Match` only when upstream sent no `Last-Modified` (If-None-Match takes precedence server-side, so a round-robin node on an older file with another ETag would answer 200 and roll the cache back). The file mtime is the local clock (bumped on every 304) and only drives the TTL and LRU — never send it upstream, or a 304 from a lagging mirror pins a stale `Release` forever.

**Integrity:** A `.sha256` sidecar is written alongside each cached file. Immutable files are verified on first serve per session; corrupt files are invalidated and re-downloaded automatically.

**Logging:** Supports `log_file: stdout` or a file path. Sends `SIGUSR1` to reopen the log file (log rotation), `SIGTERM` to stop gracefully (drains in-flight requests). Stats are logged hourly. The backend (`LogBackend`) is synchronous on purpose: the stdlib's default async dispatcher dies on the first failed write and then blocks every logging fiber once its channel fills. Sources other than `apt-larder.*` are bound at warn level so `http.server` reports unhandled handler exceptions.

**Admin server:** When `admin.enabled: true`, a second HTTP server starts on `admin.port`, bound before `READY=1`. `/api/*` routes serve a JSON REST API (includes `/api/metrics` in Prometheus format) and accept the Bearer `api_token` or the Basic UI credentials; `/*` routes serve the embedded web UI (Basic auth). A non-loopback `admin.host` without any credential fails `Config#validate!`. State-changing API requests with a foreign `Origin` are refused (403), bodies must be `application/json`.

## Testing

Uses [Spectator](https://gitlab.com/arctic-fox/spectator) (not Crystal's built-in `spec`). Test environment is detected via `crystal-env` — `Crystal.env.test?` is true when running specs.

Key spec files:
- `spec/proxy_spec.cr` — end-to-end proxy behaviour, target policy, stats, single-flight, revalidation
- `spec/cache_spec.cr` — cache operations, integrity, eviction
- `spec/server_spec.cr` — server lifecycle: bind, startup eviction, admin bind failure
- `spec/log_backend_spec.cr` — log backend, log binding, config file lookup
- `spec/admin_api_spec.cr` — REST API endpoints
- `spec/admin_auth_spec.cr` — Bearer and Basic auth, embedded assets
- `spec/admin_client_spec.cr` — admin API client used by the CLI
- `spec/config_spec.cr` — YAML config parsing, env overrides, validation
- `spec/helpers_spec.cr`, `spec/healthcheck_spec.cr`, `spec/connection_pool_spec.cr`, `spec/single_flight_spec.cr`, `spec/systemd_spec.cr`

## Config file format

Default: `apt-larder.yml` in the working directory when present; a path given with `--config`/`-c` must exist. Unknown keys are logged as warnings at startup.

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
connect_ports: [443]        # ports CONNECT tunnels may reach ([] = none)
allow_local_targets: false  # let clients reach loopback/link-local addresses
admin:
  enabled: false
  host: "127.0.0.1"   # loopback by default; 0.0.0.0 inside Docker requires credentials
  port: 8080
  api_token: ""        # Bearer token for /api/*
  ui_user: ""          # HTTP Basic user for the web UI and its API calls
  ui_password: ""      # set together with ui_user

# remaps:               # optional host remapping (bare host, host:port, or full URL)
#   deb.debian.org: my-mirror.internal
```

## Deployment

The Docker image (`docker-bake.hcl`) produces a distroless static binary image. The runtime image requires `ca-certificates` to be available for TLS certificate verification when following http→https redirects.

For the admin UI to be reachable from the host when running in Docker, set `admin.host: "0.0.0.0"` in the config, configure credentials (mandatory on a non-loopback host) and expose port 8080.

The base images of the `Dockerfile` are pinned by digest; `.github/workflows/ci.yml` is the canonical `ci-binary.yml` template, copied verbatim.
