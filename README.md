<p align="center">
  <img src="logo.svg" width="160" alt="apt-larder"/>
</p>

# apt-larder

> stock your packages, serve them fresh.

[![GitHub License](https://img.shields.io/github/license/jbox-web/apt-larder)](https://github.com/jbox-web/apt-larder/blob/master/LICENSE)
[![Build Status](https://github.com/jbox-web/apt-larder/actions/workflows/ci.yml/badge.svg)](https://github.com/jbox-web/apt-larder/actions/workflows/ci.yml)
[![GitHub Release](https://img.shields.io/github/v/release/jbox-web/apt-larder)](https://github.com/jbox-web/apt-larder/releases/latest)

## Table of contents

- [How it works](#how-it-works)
- [Caching behaviour](#caching-behaviour)
- [Running with Docker](#running-with-docker)
- [Configuration](#configuration)
- [Environment variables](#environment-variables)
- [Security model](#security-model)
- [Command line](#command-line)
- [Admin UI & REST API](#admin-ui--rest-api)
- [Health check](#health-check)
- [System integration (`extra/`)](#system-integration-extra)
- [systemd integration](#systemd-integration)
- [Signals](#signals)
- [Development](#development)
- [Architecture](#architecture)
- [Alternatives](#alternatives)
- [Compared to apt-cacher-ng](#compared-to-apt-cacher-ng)
- [TODO](#todo)
- [License](#license)

---

An HTTP caching proxy for APT package repositories. It sits between `apt` clients and upstream Debian/Ubuntu mirrors, caching `.deb` packages indefinitely and index files (`Release`, `Packages`, …) for a configurable TTL.

Designed for homelabs and CI pipelines where multiple machines repeatedly install the same packages.

## How it works

apt-larder supports two operating modes:

**Transparent proxy mode** — configure APT to use apt-larder as an HTTP proxy. APT sends absolute URLs directly to the proxy.

```
# /etc/apt/apt.conf.d/01proxy
Acquire::http::Proxy "http://apt-larder-host:3142";
```

**Host-in-path mode** — rewrite `sources.list` entries to route through apt-larder by embedding the upstream host in the path.

```
# Before
deb http://deb.debian.org/debian trixie main

# After
deb http://apt-larder-host:3142/deb.debian.org/debian trixie main
```

Both modes can coexist.

## Caching behaviour

| File type | Cached |
|-----------|--------|
| `.deb`, `.udeb`, `.ddeb` | Forever (immutable) |
| Files under `/pool/` (sources, signatures, …) and paths containing `/by-hash/` | Forever (immutable) |
| `Release`, `Packages`, `InRelease`, … | Until `index_ttl` minutes have elapsed |
| Directory paths (`…/pool/main/c/curl/`, or a path that holds cached files) | Never — relayed from upstream |

Immutable files are SHA256-verified on first serve per session. Corrupt files are invalidated and re-downloaded automatically. Incomplete downloads (Content-Length mismatch) are never cached.

Concurrent requests for the same file are deduplicated: one upstream fetch serves all waiting clients.

When an index file is due for revalidation and upstream is down (unreachable, timing out, or answering 5xx), the cached copy is served and a warning is logged: `apt update` keeps working through a mirror outage. A 4xx is passed through — the file is gone upstream.

`Range` requests (`bytes=start-end`) are supported: apt-larder seeks to the requested offset and returns `206 Partial Content`, or `416 Range Not Satisfiable` when the range starts beyond the end of the file. This allows clients to resume interrupted downloads without re-fetching the full file. A range sent with `If-Range` gets the whole file: the proxy does not keep what it would need to check that validator.

Requests are forwarded with no client header: an `Authorization` header is not passed on, so a private repository served over plain HTTP cannot be used through the cache. Over HTTPS, APT opens a `CONNECT` tunnel and authenticates end to end (nothing is cached in that case).

## Running with Docker

A `docker-compose.yml` is included for quick local testing:

```sh
docker compose up -d
# clients are pre-configured to use the proxy
docker compose exec client1 bash -c 'apt-get update && apt-get install -y redis-server'
# or download the same packages from the three clients at once
./install-package.sh redis-server
```

The admin UI is available at `http://localhost:8080` once the container is up (user `admin`, password `change-me` — the demo credentials of `apt-larder.example.yml`). Both ports are published on the loopback interface of the host only.

For production, build the image (`apt-larder:latest`, distroless) or the static binaries:

```sh
mise dev:docker-image  # builds the apt-larder:latest image via docker buildx bake
mise release:static    # builds the linux/amd64 and linux/arm64 static binaries into packages/
```

Mount a config file, a cache volume, and a logs volume. The image runs as uid 65532 (`nonroot`): the two host directories must belong to it.

```sh
sudo install -d -o 65532 -g 65532 /srv/apt-cache /srv/apt-logs
docker run -d \
  -p 3142:3142 \
  -p 8080:8080 \
  -v /srv/apt-larder.yml:/home/nonroot/apt-larder.yml:ro \
  -v /srv/apt-cache:/home/nonroot/cache \
  -v /srv/apt-logs:/home/nonroot/logs \
  apt-larder:latest server --config /home/nonroot/apt-larder.yml
```

Publishing the admin port means `admin.host: "0.0.0.0"` in that config, which in turn requires credentials (see [Authentication](#authentication)).

The image declares a `HEALTHCHECK` that calls `apt-larder healthcheck` (see
[Health check](#health-check)). It probes the proxy itself and needs no config
and no admin server — a container started with nothing but defaults reports
healthy as soon as it serves.

## Configuration

Default config file: `apt-larder.yml` in the working directory, used when it exists. A file named with `--config` / `-c` must exist: apt-larder refuses to start on a path it cannot find rather than run on defaults. Unknown keys are reported in the log at startup.

```yaml
cache_dir: ./cache          # where packages are stored on disk
index_ttl: 5                # minutes before index files are revalidated
max_redirects: 5            # max HTTP redirects to follow per request
connect_timeout: 10         # upstream connect timeout, seconds
read_timeout: 30            # upstream read timeout, seconds
log_file: stdout            # "stdout" or a file path
log_level: info             # trace, debug, info, warn, error, fatal, off
quiet: false                # when true, only MISS and ERR are logged (application-level filter)
evict_after_days: 0         # delete files not accessed for N days (0 = disabled)
max_cache_size_gb: 0        # max cache size in GB — evicts LRU when exceeded (0 = disabled)
server_host: "0.0.0.0"
server_port: 3142
connect_ports: [443]        # ports a CONNECT tunnel may be opened to ([] = no tunnels)
allow_local_targets: false  # let clients reach loopback / link-local addresses

admin:
  enabled: false
  host: "127.0.0.1"         # bind address — 0.0.0.0 inside Docker; requires credentials
  port: 8080
  api_token: ""             # Bearer token for /api/*
  ui_user: ""               # HTTP Basic user for the web UI and its API calls
  ui_password: ""           # set together with ui_user

# Optional host remapping. Redirects requests for a given upstream host to a
# different mirror. The cache key always uses the original hostname.
# Value can be a bare hostname, host:port, or a full URL. A remap target may
# be a local address (localhost:8081): it comes from this file, not from clients.
# remaps:
#   deb.debian.org: my-mirror.internal
#   archive.ubuntu.com: "http://ubuntu-mirror.lan:80"
```

"Accessed" means downloaded, revalidated or served: a cache hit refreshes the timestamp eviction sorts on (at most once per hour per file). Eviction runs once at startup, then every hour.

Sizes are shown in binary units (KiB, MiB, GiB) by the logs, the CLI and the web UI alike.

## Environment variables

Any scalar config field can be overridden with an environment variable — useful for Docker secrets and CI pipelines. Env vars take precedence over the config file. `remaps` has no variable: it is set in the file.

Convention: `APT_LARDER_<FIELD>` (uppercase, underscores). Nested admin fields use `APT_LARDER_ADMIN_<FIELD>`.

| Variable | Config field |
|----------|-------------|
| `APT_LARDER_CACHE_DIR` | `cache_dir` |
| `APT_LARDER_INDEX_TTL` | `index_ttl` |
| `APT_LARDER_MAX_REDIRECTS` | `max_redirects` |
| `APT_LARDER_CONNECT_TIMEOUT` | `connect_timeout` |
| `APT_LARDER_READ_TIMEOUT` | `read_timeout` |
| `APT_LARDER_LOG_FILE` | `log_file` |
| `APT_LARDER_LOG_LEVEL` | `log_level` |
| `APT_LARDER_QUIET` | `quiet` |
| `APT_LARDER_EVICT_AFTER_DAYS` | `evict_after_days` |
| `APT_LARDER_MAX_CACHE_SIZE_GB` | `max_cache_size_gb` |
| `APT_LARDER_SERVER_HOST` | `server_host` |
| `APT_LARDER_SERVER_PORT` | `server_port` |
| `APT_LARDER_ALLOW_LOCAL_TARGETS` | `allow_local_targets` |
| `APT_LARDER_CONNECT_PORTS` | `connect_ports` (comma-separated: `443,8443`) |
| `APT_LARDER_ADMIN_ENABLED` | `admin.enabled` |
| `APT_LARDER_ADMIN_HOST` | `admin.host` |
| `APT_LARDER_ADMIN_PORT` | `admin.port` |
| `APT_LARDER_ADMIN_API_TOKEN` | `admin.api_token` |
| `APT_LARDER_ADMIN_UI_USER` | `admin.ui_user` |
| `APT_LARDER_ADMIN_UI_PASSWORD` | `admin.ui_password` |

Boolean fields accept `true`, `1`, `yes` (case-insensitive) as truthy. A numeric variable that does not parse stops the startup with an error naming it.

Docker Compose example:
```yaml
services:
  apt-larder:
    environment:
      APT_LARDER_ADMIN_API_TOKEN: "${API_TOKEN}"
      APT_LARDER_ADMIN_UI_USER: "admin"
      APT_LARDER_ADMIN_UI_PASSWORD: "${UI_PASSWORD}"
```

## Security model

apt-larder is meant for a network whose clients are trusted to install packages, not for the open Internet. Within that, three limits apply by default.

**Clients cannot reach local addresses through the proxy.** A request — `GET` or `CONNECT`, direct or through a redirect — whose target is, or resolves to, a loopback, unspecified (`0.0.0.0`) or link-local address is answered `403`. This keeps a client of port 3142 away from services bound to the proxy host's loopback interface (the admin server among them) and from cloud instance metadata. Addresses on the LAN are not concerned: a mirror at `192.168.1.10` is the normal case. Targets named in `remaps` are always allowed, since they come from the configuration — remap a host to `localhost:8081` to serve a mirror running next to the proxy. `allow_local_targets: true` lifts the limit for every client.

**`CONNECT` tunnels only reach the ports of `connect_ports`**, `[443]` by default. Add the port of an HTTPS repository served elsewhere (`connect_ports: [443, 8443]`); an empty list disables tunnels.

**The admin server is not exposed without credentials.** It binds to loopback by default; with any other `admin.host`, apt-larder refuses to start unless `api_token`, or `ui_user` and `ui_password`, are set.

The local-address check resolves the target name, and the connection resolves it again: a name whose answer changes between the two is not caught for `GET` requests (tunnels are checked on the address actually reached). Authenticating the admin server is what covers that residue.

## Command line

```sh
apt-larder server [-c apt-larder.yml]        # run the proxy
apt-larder info                              # version and build information
apt-larder healthcheck [-c apt-larder.yml]   # probe the proxy, exit 0 or 1
```

The remaining subcommands talk to the admin API of a running server, with the address and token of the same config file (`admin.enabled: true` is required on the server):

```sh
apt-larder stats                                    # hits, misses, revalidations, errors, tunnels, bytes served, cache size
apt-larder cache list [--prefix deb.debian.org]     # one page of entries (--page, --per-page)
apt-larder cache list --all --search curl --sort size --order desc
apt-larder cache invalidate "deb.debian.org/debian/pool/main/c/curl/curl_8.5.0-2_amd64.deb"
apt-larder cache flush                              # delete every entry
apt-larder evict [--max-age-days 7]                 # evict files not accessed for N days
```

`evict` without `--max-age-days` uses `evict_after_days`; when that is `0` (time-based eviction disabled), nothing is evicted.

## Admin UI & REST API

When `admin.enabled: true`, a second server starts on `admin.port` with:

- **Web UI** at `/` — dashboard (hit rate, bytes served, cache size, …), cache browser with search/sort/pagination (DataTables), and an eviction form. Everything it loads is embedded in the binary: it works without Internet access.
- **REST API** at `/api/*` — programmatic cache management.

### API endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/health` | `{"status":"ok","version":"..."}` |
| `GET` | `/api/stats` | Cumulative counters (hits, misses, revalidations, errors, bytes, tunnels) and `cache_bytes`, the disk space used by the cache |
| `GET` | `/api/metrics` | Prometheus text format (counters + cache_entries and cache_bytes gauges) |
| `GET` | `/api/cache` | Paginated entry list (`?prefix=&search=&sort=&order=&page=&per_page=`): `search` is a case-insensitive substring of the key, `sort` is `key` (default), `size` or `mtime`, `order` is `asc` (default) or `desc`, `per_page` is capped at 200 |
| `DELETE` | `/api/cache` | Flush the entire cache |
| `DELETE` | `/api/cache/:key` | Invalidate one entry (key URL-encoded) |
| `POST` | `/api/evict` | Evict files not accessed for N days — body: `{"max_age_days":N}`, N from 1 to 36500 (`400` otherwise). Without a body, `evict_after_days` is used; when that is `0`, nothing is evicted |

Responses are `application/json`, except `/api/metrics` (Prometheus text). Errors return `{"error":"..."}`.

A request body must be sent as `Content-Type: application/json` (`415` otherwise), and a `POST` or `DELETE` carrying an `Origin` header that is not the admin server itself is refused with `403`: a page open in the operator's browser cannot drive the API.

### Prometheus metrics

`GET /api/metrics` returns Prometheus text format 0.0.4:

```
# HELP apt_larder_hits_total Total cache hits served to clients.
# TYPE apt_larder_hits_total counter
apt_larder_hits_total 1234
# HELP apt_larder_misses_total Total upstream fetches triggered.
# TYPE apt_larder_misses_total counter
apt_larder_misses_total 56
# HELP apt_larder_revalidations_total Total 304 Not Modified revalidations.
# TYPE apt_larder_revalidations_total counter
apt_larder_revalidations_total 12
# HELP apt_larder_errors_total Total requests that resulted in an error.
# TYPE apt_larder_errors_total counter
apt_larder_errors_total 3
# HELP apt_larder_bytes_served_total Total bytes written to clients from cache.
# TYPE apt_larder_bytes_served_total counter
apt_larder_bytes_served_total 4398046511
# HELP apt_larder_tunnels_total Total CONNECT tunnels successfully established.
# TYPE apt_larder_tunnels_total counter
apt_larder_tunnels_total 42
# HELP apt_larder_cache_entries Current number of files tracked in the cache.
# TYPE apt_larder_cache_entries gauge
apt_larder_cache_entries 847
# HELP apt_larder_cache_bytes Current disk space used by the cached files, in bytes.
# TYPE apt_larder_cache_bytes gauge
apt_larder_cache_bytes 52428800000
```

Prometheus scrape config:

```yaml
scrape_configs:
  - job_name: apt-larder
    static_configs:
      - targets: ["apt-larder-host:8080"]
    metrics_path: /api/metrics
    bearer_token: "your-api-token"   # omit if api_token is empty
```

### Authentication

Two credentials, each optional:

- **API token** (`api_token`): scripts, the CLI and Prometheus send `Authorization: Bearer <api_token>` to `/api/*`.
- **UI credentials** (`ui_user` and `ui_password`, set together): HTTP Basic Auth on the web UI (`/*`). The browser sends the same credentials on the API calls the UI makes, and `/api/*` accepts them.

As soon as either is configured, `/api/*` requires one of the two — protecting the pages never leaves the API they drive open. To use the web UI on a protected server, set the UI credentials: the UI cannot send a Bearer token. With neither configured the admin server is open, which is only accepted on a loopback `admin.host`.

## Health check

```sh
apt-larder healthcheck [--config apt-larder.yml]
```

Performs a `GET /_health` against the proxy (`server_host` / `server_port`) and
exits `0` when it answers 2xx, `1` otherwise. Connect and read are both bounded
at 2 seconds — a probe that hangs reports nothing. Failures print one line and
no backtrace:

```
healthy: proxy answered /_health on 127.0.0.1:3142
unhealthy: cannot reach the proxy at 127.0.0.1:3142 — Connection refused
unhealthy: proxy answered 503 on 127.0.0.1:3142/_health
```

It probes the **proxy**, not the admin API. The admin server is optional and
off by default: a probe aimed at it reported unhealthy on every deployment
without an admin server, while the proxy was serving packages perfectly. Gating
container health on the one surface the container exists to provide means a
default `docker run` with no config file at all goes green.

`/_health` is answered by the proxy before any resolution, cache lookup or
upstream call, and is deliberately absent from the counters, from
`/api/metrics` and from the access log: a probe firing every 30 seconds would
otherwise book roughly 2,880 invented errors a day. The leading underscore
keeps it collision-free — `_health` is not a legal hostname, so no host-in-path
request can produce it, and `GET http://mirror/_health` is still proxied
upstream rather than shadowed.

When `server_host` is a wildcard (`0.0.0.0`, `::`), the probe dials `127.0.0.1`
— that is what a wildcard bind actually answers on from inside the container.

The baked `HEALTHCHECK` passes no `--config`: the probe reads `apt-larder.yml`
from the image's working directory (`/home/nonroot`) when one is mounted there
— the layout shown in [Running with Docker](#running-with-docker) — and the
`APT_LARDER_*` variables. One residual caveat: a config mounted elsewhere that
moves `server_port` is not seen, and the probe dials the default `3142`.
Override the healthcheck to pass it (`["CMD", "apt-larder", "healthcheck", "-c",
"/path/apt-larder.yml"]`).

This subcommand exists because the release image is distroless — no shell, no
curl — so the only process able to speak HTTP inside the container is
apt-larder itself.

## System integration (`extra/`)

The `extra/` directory contains ready-to-use files for running apt-larder as a managed system service:

| File | Description |
|------|-------------|
| `apt-larder.service` | systemd unit (`Type=notify`, watchdog, hardening) |
| `apt-larder.yml.example` | Production config with system paths |
| `apt-larder.logrotate` | logrotate config — sends `SIGUSR1` after rotation |
| `grafana-dashboard.json` | Grafana dashboard for the Prometheus metrics |

See [`extra/README.md`](extra/README.md) for installation instructions.

## systemd integration

When managed by systemd with `Type=notify`, apt-larder:
- Sends `READY=1` once the proxy and, when enabled, the admin server are bound and listening — systemd won't mark the service as started until then, and a port that cannot be bound fails the start.
- Sends `STOPPING=1` on `SIGTERM` before draining in-flight requests.
- Resets the watchdog timer (`WATCHDOG=1`) at half the configured `WatchdogSec` interval.
- Updates `STATUS=` with hourly stats (visible in `systemctl status apt-larder`).

A ready-to-use unit file is provided in [`extra/apt-larder.service`](extra/README.md).

## Signals

| Signal | Effect |
|--------|--------|
| `SIGTERM` | Graceful shutdown — stops accepting new connections, waits for in-flight requests to finish |
| `SIGUSR1` | Reopen the log file (for log rotation with tools like `logrotate`). If the file cannot be reopened, logging carries on in the previous one |

The log is written synchronously, and a destination that stops accepting writes (full partition, closed pipe) never blocks or fails a request: the problem is reported once on standard error and entries are dropped until writes succeed again. Warnings and errors of the HTTP layer (a handler that raised and was answered `500`) are logged alongside the application's own lines.

## Development

Prerequisites: [mise](https://mise.jdx.dev/). The toolchain is pinned to
Crystal **1.20.3** in `mise.toml` — always drive the compiler through `mise` so
this exact version is used. A newer `crystal` on your `PATH` may compile code
that relies on post-1.20 APIs and then break the CI/Docker build.

```sh
mise dev:deps      # install shards
mise dev:check     # build + lint + test in one shot
mise dev:build     # compile dev binary → bin/apt-larder
mise dev:spec      # run tests
mise dev:ameba     # lint
mise dev:format    # format source
```

Run a single spec file (extra args are forwarded to the task):

```sh
mise dev:spec spec/proxy_spec.cr
```

## Architecture

```
src/apt-larder.cr          Entry point: config loading, log setup, CLI start
src/apt_larder/
  cli.cr                   Admiral CLI — subcommands: server, info, healthcheck, stats, cache, evict
  healthcheck.cr           Self-probe for Docker HEALTHCHECK — exits 0/1 on the proxy /_health
  config.cr                YAML config, environment overrides, validation
  admin_config.cr          Nested admin config (port, auth)
  helpers.cr               Immutability heuristic, CONNECT target parsing, local-address test, byte formatting
  log_backend.cr           Synchronous log backend that survives a failing destination, log reopening
  proxy.cr                 HTTP handler: resolve → target policy → ensure_cached → serve; CONNECT tunnels
  cache.cr                 Filesystem cache — atomic writes, TTL, SHA256 and validator sidecars, LRU eviction
  single_flight.cr         Concurrent deduplication — one upstream fetch per key
  connection_pool.cr       Per-host HTTP connection pool with stale-connection retry and idle sweep
  server.cr                HTTP server lifecycle (start/stop, graceful shutdown, background loops)
  systemd.cr               systemd sd_notify integration (READY=1, STOPPING=1, watchdog, STATUS=)
  admin/
    server.cr              Admin server: routing + authentication
    api.cr                 JSON REST API handlers (/api/*)
    client.cr              HTTP client of the admin API, used by the CLI subcommands
    handler.cr             Serves embedded HTML/CSS/JS assets (/*)
src/assets/admin/
  index.html / app.js / style.css   Web UI compiled into the binary at build time
  vendor/                           jQuery and DataTables, embedded too (see its README)
```

Request flow: `Proxy#handle` → `resolve` → `ensure_cached` → `SingleFlight#run` → `download` (conditional GET replaying the upstream `Last-Modified`/`ETag`) → `serve`.

## Alternatives

| Project | Language | Notes |
|---------|----------|-------|
| [apt-cacher-ng](https://www.unix-ag.uni-kl.de/~bloch/acng/) | C++ | The reference implementation. More configurable, requires more setup. |
| [soulteary/apt-proxy](https://github.com/soulteary/apt-proxy) | Go | Also caches YUM and APK, very small binary (~2 MB). |
| [lox/apt-proxy](https://github.com/lox/apt-proxy) | Go | Simple APT-only proxy, minimal feature set. |
| [apt-cacher-rs](https://github.com/cgzones/apt-cacher-rs) | Rust | apt-cacher-ng rewrite in Rust, includes a minimal web UI. |
| Squid | C | General-purpose HTTP proxy; can cache APT with the right config but not purpose-built. |

## Compared to apt-cacher-ng

apt-cacher-ng is the reference APT proxy. The two tools cover largely the same ground — caching, deduplication, integrity checking, CONNECT tunneling — and apt-cacher-ng is more mature and more configurable. apt-larder trades configuration flexibility for operational simplicity.

### Where apt-larder is genuinely simpler

**Single static binary, no runtime dependencies.**
The release build is a fully-static Linux binary. The Docker image is distroless. apt-cacher-ng requires a C++ runtime, several shared libraries, and typically runs under systemd. apt-larder is a single file you drop and run.

**Zero required configuration.**
apt-larder works out of the box with sensible defaults. apt-cacher-ng requires at minimum a `CacheDir` and `Port` in its config, and correct `Remap-*` entries for each distribution you want to cache. apt-larder infers immutability from URL structure and needs no per-distribution setup.

**Intentionally fixed immutability rules.**
apt-cacher-ng exposes `VfilePatternEx` and `PfilePatternEx` for fine-grained control over which URLs are volatile or permanent. apt-larder uses a hardcoded heuristic (`.deb`/`.udeb`/`.ddeb`, `/pool/`, `/by-hash/`) that covers all standard Debian and Ubuntu repositories without configuration.

### What apt-larder does not have

- **Import from local archives.** apt-cacher-ng can seed its cache from an existing local Debian mirror. apt-larder populates its cache on demand only.
- **acngfs.** apt-cacher-ng includes a FUSE filesystem that exposes the cache as a virtual Debian archive. apt-larder has no equivalent.
- **Fine-grained URL pattern control.** If you need custom rules for non-standard repository layouts, apt-cacher-ng's pattern system is more flexible.

### When to choose apt-cacher-ng instead

- You need fine-grained URL pattern control for non-standard repositories.
- You need to seed the cache from an existing local mirror.
- You are already running apt-cacher-ng and it is working.

## TODO

- **sendfile(2) zero-copy serving** — the current implementation uses a 64 KB buffered copy loop. `Socket#sendfile` was merged into Crystal master in [PR #16665](https://github.com/crystal-lang/crystal/pull/16665) (milestone 1.21.0). Once Crystal 1.21 ships, `serve` can be updated to use it, eliminating the userspace copy on the hot HIT path.

## License

MIT
