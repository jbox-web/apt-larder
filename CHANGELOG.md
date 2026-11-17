# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `apt-larder licenses` prints the third-party notices embedded in the
  binary: the runtime shards, the C libraries it links statically (OpenSSL,
  PCRE2, libyaml, zlib, Boehm GC, musl, libgcc) and the Crystal runtime,
  assembled at build time from `licenses.manifest`

### Fixed

- The macOS binaries no longer depend on Homebrew's OpenSSL: they link
  `openssl@4` statically, the same on arm64 and Intel, and only load
  libraries macOS ships. Those of 2.0.0 only started on a Mac with Homebrew's
  `openssl@4` (arm64) or `openssl@3` (Intel) installed at its default path

### Changed

- Releases are built and published by crystalreleaser
  (`.crystalreleaser.yml`, `.github/workflows/release.yml`); the assets keep
  their names, `apt-larder-<os>-<arch>` and its `.sha256`

## [2.0.0] - 2026-11-17

### Security

- Clients can no longer make the proxy reach a loopback, unspecified or
  link-local address, with a `GET` or a `CONNECT`, directly or through a
  redirect: such a target is answered `403`. Targets named in `remaps` stay
  allowed; `allow_local_targets: true` (`APT_LARDER_ALLOW_LOCAL_TARGETS`)
  restores the previous behaviour
- `CONNECT` tunnels are limited to the ports of the new `connect_ports`
  setting (`APT_LARDER_CONNECT_PORTS`), `[443]` by default
- The UI credentials (`ui_user` / `ui_password`) now also protect `/api/*`,
  which accepts them alongside the Bearer token: protecting the web UI no
  longer leaves the API it drives open
- apt-larder refuses to start with an admin server bound to a non-loopback
  address and no credential, and with only one of `ui_user` / `ui_password` set
- The admin API refuses state-changing requests whose `Origin` is another
  site (`403`) and request bodies not declared as `application/json` (`415`)
- The admin UI embeds jQuery and DataTables instead of loading them from CDNs
- Upstream URLs are logged without their query string and credentials

### Changed

- **Breaking:** an HTTPS repository on a port other than 443 needs that port
  in `connect_ports`; a mirror reached by a local address needs a `remaps`
  entry or `allow_local_targets: true`; an admin server on `0.0.0.0` needs
  credentials
- **Breaking:** a config file named with `--config` must exist. Without the
  flag, `apt-larder.yml` is used when present and the defaults otherwise
- Eviction follows the last access: a cache hit refreshes the timestamp
  eviction sorts on (at most once per hour per file), so `evict_after_days`
  and `max_cache_size_gb` no longer evict packages that are served regularly.
  Eviction also runs once at startup instead of an hour later
- `POST /api/evict` and `apt-larder evict` no longer evict anything when
  `evict_after_days` is `0` and no age is given; `max_age_days` must be
  between 1 and 36500
- Files under `/pool/` are immutable only when their name has an extension; a
  directory path is relayed from upstream instead of being cached
- A stale index file is served when upstream is unreachable or answers 5xx
- An unsatisfiable `Range` is answered `416`, and a range sent with `If-Range`
  gets the whole file
- An upstream status other than 200, 304, 4xx and 5xx is answered `502`
  instead of being relayed with an error body
- The log is written synchronously, and also carries the warnings and errors
  of the HTTP layer (unhandled exceptions answered `500`)
- Sizes are printed in binary units with their proper names (KiB, MiB, GiB)
  by the logs, the CLI and the web UI
- Unknown configuration keys are reported at startup; an environment variable
  that does not parse stops the startup with an error naming it
- The client subcommands (`stats`, `cache`, `evict`, `healthcheck`) no longer
  open the server's log file
- The web UI reports failed API calls in a banner, and its "Last modified"
  column is now "Last used"
- CI: workflow taken from the shared binary-project template (format check,
  docs, static build, linux arm64 and nightly legs); the release workflow runs
  the tests first, publishes from a single job and no longer uploads the
  `.dwarf` files
- Docker: base images pinned by digest, Crystal held to 1.20.3; the demo
  compose publishes its ports on the loopback interface only

### Added

- Disk space used by the cache: a "Cache size" card on the dashboard, a
  `cache_bytes` field in `/api/stats` and an `apt_larder_cache_bytes` gauge in
  `/api/metrics` (#1). Counted on the cached files, sidecars excluded: the
  figure `max_cache_size_gb` is enforced against
- Grafana dashboard: "Cache size" stat and graph, and the tunnel rate in
  "Request rate"
- `/api/cache` accepts `search` (case-insensitive substring of the key),
  `sort` (`key`, `size` or `mtime`) and `order` (`asc` or `desc`)
- `apt-larder cache list` accepts `--search`, `--sort` and `--order`
- `apt-larder stats` shows the tunnel count and the cache size

### Fixed

- A cache directory configured with a trailing slash (`/var/cache/apt-larder/`)
  made eviction report deletions without deleting anything, and the cache
  browser list every key without its first character
- A path cached as a file (the index page of a mirror directory) kept every
  file below it from being stored: such an entry is now dropped when a
  directory is needed in its place
- A failed log write (full partition, closed stdout pipe, log file that cannot
  be reopened after rotation) could end up blocking every request; the log
  backend now reports the failure once on standard error and carries on
- The admin server is bound before the service is announced as ready: a port
  already in use fails the start instead of leaving the proxy running without it
- A cached file that vanished from disk is downloaded again within the same
  request instead of answering 502
- Temporary download files are no longer listed, counted, evicted or flushed as
  cache entries, and the ones left by a previous run are removed at startup
- Requests waiting on a download in flight always get the status of that
  download
- A request failing on a freshly opened upstream connection is no longer
  retried (the wait before the 502 was doubled)
- Idle upstream connections to hosts that are not contacted again are closed
  after their keep-alive instead of being kept until shutdown
- `GET /api/cache` with a very large `page` answers an empty page instead of 500
- `DELETE /api/cache/<directory>` answers 404 instead of 204
- `CONNECT` with a port that is not a number answers 400 instead of tunnelling
  to port 443
- Listing the cache, hashing a large file and scanning the cache directory no
  longer stall the other requests; the directory scan at startup no longer
  delays readiness, and paging through `GET /api/cache` reuses one scan
- systemd unit: `TimeoutStopSec` raised above the drain timeout, `After=`
  matches `Wants=network-online.target`, documentation URL fixed
- `extra/README.md`: the service user is created before the config file is
  installed for its group, and the binary installation step is documented

- Admin UI cache browser: only the first 200 entries were listed, the UI asking
  for 5000 per page while the API caps `per_page` at 200. The table now pages,
  sorts and searches through the API, so it covers the whole cache; the "Type"
  column is no longer sortable
- `apt-larder cache list --all` stopped at the first 200 entries, for the same
  reason; it now walks every page. Without `--all`, the page count is computed
  from the page size the server applied, not from the `--per-page` asked for
- Admin UI cache browser: pagination buttons were stacked one per line and
  reduced to the current page, the sidebar `nav button` styles leaking onto
  the DataTables pagination
- Admin UI cache browser: keys are rendered as text instead of HTML

## [1.3.1] - 2026-09-26

### Fixed

- Index revalidation replays the upstream `Last-Modified` (kept in a new
  `.validators` sidecar, with the `ETag` as a fallback when there is none)
  instead of sending the local file mtime as `If-Modified-Since`. The mtime is
  bumped to "now" on every 304, so a 304 from a mirror that had not synced yet
  pushed it past the next upstream
  `Last-Modified`, and every later revalidation was answered 304: APT kept
  receiving the old `InRelease` until it failed with "Release file … is
  expired". Index files cached before this fix carry no validators and are
  fetched once unconditionally
- Requests whose cache key ends in `.sha256` or `.validators` (in any case, for
  case-insensitive filesystems) are relayed from upstream without touching the
  cache. They share the key namespace with the sidecars, so a client could read
  the sidecar of another entry or, on an upstream 200, overwrite it and have
  its content replayed as request headers. `DELETE /api/cache/:key` refuses
  such keys with 400: removing a `.sha256` alone left its package served
  without integrity check
- `CONNECT` to a host refusing the connection answers 502 instead of 200. On
  some platforms (macOS 27 with Crystal 1.20.3) a refused connect does not
  raise until the first write, after the 200 had been sent

## [1.3.0] - 2026-08-20

### Added

- `GET /_health` on the proxy — a side-effect-free liveness endpoint, answered
  before any resolution, cache lookup or upstream call, and excluded from the
  counters, from `/api/metrics` and from the access log
- `apt-larder healthcheck` subcommand — probes `GET /_health` on the proxy and
  exits 0 (healthy) or 1 (unhealthy), with a 2s bound on connect and read. It
  needs no config file and no admin server, so a container started on pure
  defaults reports healthy. Dials `127.0.0.1` when the server binds a wildcard
  address
- `HEALTHCHECK` in the Docker image, calling the binary itself: the distroless
  runtime has no shell and no curl. `docker-compose.yml` overrides it on a
  shorter cycle and gates the client containers on `service_healthy`
- Spec coverage for `Admin::Client`: verbs, query string, request body, Bearer
  header, 204 and 404 branches, unreachable server, connect timeout

## [1.2.0] - 2026-08-07

### Added

- CONNECT tunnel counter, exposed in the stats log line, the JSON API, the
  Prometheus metrics and the web UI

### Changed

- Pin the Crystal toolchain to 1.20.3 and build the Docker image on Alpine 3.24
- Verify SHA256 in the single-flight leader only, so a burst of concurrent
  requests for the same key hashes the file once instead of once per fiber
- Flush the cache from the admin API with a single glob scan instead of loading
  the whole entry list into memory
- Discard pooled connections idle for more than 50s on checkout, avoiding a
  wasted round-trip on a keep-alive socket the upstream has already closed
- Close evicted and stale pooled connections outside the pool mutex, so a
  `close(2)` never serialises other fibers
- Cap the graceful-shutdown drain at 30s instead of waiting indefinitely

### Fixed

- Drain redirect bodies through `body_io`: a 301 carrying a body (nginx
  http→https) left it in the socket, and the next request on that pooled
  connection failed with `Invalid HTTP response`
- Retry any upstream failure raised before the response body starts, not just
  `IO::Error` — an unparseable response head was fatal on the first attempt
- Plug a fiber leak on every CONNECT tunnel
- Parse bracketed IPv6 literals in CONNECT targets, with or without a port
- Preserve the query string on upstream requests, both in host-in-path mode and
  when reaching a signed URL through a redirect
- Report 0 bytes served for HEAD requests instead of inflating
  `bytes_served_total`
- Write the `.sha256` sidecar before renaming the data file into place, so a
  crash can no longer leave a file that is served unverified
- Re-download instead of returning 500 when a cached file vanishes mid-check
  (concurrent eviction)
- Report `cache_entries` from a boot-time disk count, so the gauge reflects a
  warm cache instead of starting at 0
- Close the old descriptor on log rotation and serialise the log globals,
  fixing a file-descriptor leak per `SIGUSR1`
- Reject zero-length suffix ranges (`Range: bytes=-0`)

### Security

- Reject path-traversal keys on admin `DELETE /api/cache/:key` before any
  filesystem access; a decoded `../..` key could otherwise delete files outside
  the cache root, exploitable whenever `api_token` is empty
- Ignore keys containing `..` in `Cache#invalidate`, as defense in depth
- Compare admin Bearer tokens and Basic credentials in constant time, so
  response timing no longer leaks them

## [1.1.0] - 2026-06-16

### Added

- Log client IP address in access log
- Pass upstream error status codes through to client
- Support path prefix in remap targets (e.g. `deb.debian.org: mirror.internal/debian`)

### Fixed

- Flush tunnel writes to prevent TLS handshake failure on CONNECT proxying
- Log fetch failures as WARN without stack trace
- Improve access log format: client IP on TUNNEL lines, ERR/FAIL tags
- Remove `MemoryDenyWriteExecute` from systemd service (incompatible with Crystal runtime)

## [1.0.0] - 2026-06-02

Initial release.
