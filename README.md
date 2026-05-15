# ssh-mux-helper

Bash helpers for OpenSSH-centric SSH workflows: argument parsing, validation,
and multiplexed connections (`ControlMaster` / `ControlPath`).

The main script is [`ssh-mux-helper.sh`](ssh-mux-helper.sh). Several wrapper
variants live in that file for comparison, copy-paste reuse, or integration
into automation.

## Requirements

- Bash
- OpenSSH `ssh` with multiplexing support

## Quick start

```bash
chmod +x ssh-mux-helper.sh
./ssh-mux-helper.sh [ssh connection arguments…]
```

Connection-related arguments are taken from `"$@"` when the script runs; see
the commented examples at the bottom of `ssh-mux-helper.sh`.

## Documentation

Full design notes, precedence rules, and architecture are in
[`ssh-mux-helper.md`](ssh-mux-helper.md) (source for future `--help` / man page).

## License

MIT — see [LICENSE](LICENSE).
