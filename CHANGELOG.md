# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-05-14

### Changed

- OpenSSH client validation (`__validate_openssh`): resolve the SSH binary with POSIX `command -v` instead of the external `which` utility; require an executable path and detect OpenSSH via `ssh -V`.

## [0.1.0] - 2026-05-14

### Added

- Initial published version: Bash helpers for OpenSSH-centric SSH workflows, multiplexed connections, and related utilities (`__ssh_mux_helper`).
