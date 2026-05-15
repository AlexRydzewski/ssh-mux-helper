# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.1] - 2026-05-15

### Changed

- Host option checks in `__build_openssh_options`: use inline `OPTION_` membership test (`case "$IFS${OPTION_[*]}$IFS"`) instead of `__option_take_care_of_ssh_host` / `__append_ssh_host_if_needed` helpers.

## [0.3.0] - 2026-05-15

### Changed

- Rename `__ssh_mux_helper` to `ssh-mux-helper.sh`; move long documentation to `ssh-mux-helper.md` and replace `README.md` with a short overview.
- Wire `__ssh` to use parsed `ssh_options_` from `__build_openssh_options` instead of raw `"$@"`.
- Host handling: default `OPTION_` includes `take-care-of-the-ssh-host`; append host only when that option is enabled and a host was parsed (`__append_ssh_host_if_needed`).
- Reset `argv_` at the start of `__prepare_argv`; use `argv_leftover_` for unparsed outer arguments.
- Drop debug output (`echo` in normalize loop, `set -x`, live execution examples at end of script); keep commented section 5 examples only.

## [0.2.0] - 2026-05-14

### Changed

- OpenSSH client validation (`__validate_openssh`): resolve the SSH binary with POSIX `command -v` instead of the external `which` utility; require an executable path and detect OpenSSH via `ssh -V`.

## [0.1.0] - 2026-05-14

### Added

- Initial published version: Bash helpers for OpenSSH-centric SSH workflows, multiplexed connections, and related utilities (`ssh-mux-helper.sh`, formerly `__ssh_mux_helper`).
