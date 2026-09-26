# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
