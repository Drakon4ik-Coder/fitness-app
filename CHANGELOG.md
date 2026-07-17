# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]
### Added
- Nightly off-host Postgres backups: `ops/db-backup` sidecar in
  `docker-compose.prod.yml` (pg_dump → rclone, retention pruning,
  healthchecks.io dead-man ping) + `docs/OPERATIONS.md` with restore drill,
  uptime-monitoring and reboot-survival runbooks (KAN-46).
- Forced-update gate: `/health/` serves `min_supported_build` (env
  `MIN_SUPPORTED_APP_BUILD`, default 0 = disabled); on startup the app
  compares its versionCode and blocks with an update dialog when below,
  failing open when offline (KAN-100).
- 

### Changed
- 

### Deprecated
- 

### Removed
- 

### Fixed
- 

### Security
- 
