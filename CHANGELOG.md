# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
