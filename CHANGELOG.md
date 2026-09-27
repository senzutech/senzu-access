# Changelog

All notable changes are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - 2026-09-27

### Added

- `senzu-access-setup.sh`: a named `senzu` account reached with Senzu's SSH key only, full sudo
  while open, closed by default; `senzu-access on|off|status|sync`; a request file the Hermes
  user writes and a systemd path unit (with a cron safety net) that applies it. The Hermes user
  gets no sudo rights. `--uninstall` removes everything.
- Container tests on Debian 12 and Ubuntu 24.04 over real SSH connections.

[Unreleased]: https://github.com/senzutech/senzu-access/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/senzutech/senzu-access/releases/tag/v0.1.0
