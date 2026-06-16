# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
