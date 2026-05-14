# SSH wrapper

## Purpose of This Script

This project primarily explores different approaches to building Bash SSH
wrappers around OpenSSH semantics and multiplexed connections.

Some parts of the script are also intentionally preserved as practical
reference implementations and reusable examples that may later be copied,
adapted, simplified, or integrated into other scripts depending on the
required complexity and safety level.

As a result, several variants of similar functionality may intentionally
coexist in order to demonstrate different tradeoffs, implementation styles,
and abstraction levels.

## Design notes

The central parameter of any SSH connection is the target host. It must always
be defined.

The next most commonly customized parameter is the remote user, because it
directly determines the access scope on the remote system. If no user is
specified, SSH falls back to the current local user.

The port comes next. SSH uses port `22` by default, but it is commonly changed
for basic hardening and to reduce noise from automated scans.

Host, user, and port may be provided in URI-like form:

```text
[ssh://][user@]host[:port]
```

This syntax is supported by OpenSSH and many OpenSSH-like SSH clients.
Alternatively, user and port may be specified through regular SSH options:

```text
-l user -p port
```

OpenSSH additionally supports configuration directives passed through `-o`:

```text
-o User=user -o "User user"
-o Port=port -o "Port port"
```

Clients that support at least part of the OpenSSH `-o` syntax:

| Client / implementation | `-l` / `-p` support | `-o key=value` support | Notes |
| --- | --- | --- | --- |
| OpenSSH `ssh` | yes | full | Reference implementation for modern SSH CLI behavior |
| Dropbear | yes | partial | Supports some OpenSSH-style options, but not full compatibility |
| PuTTY `plink` | yes (`-l`, `-P`) | no | Uses its own CLI syntax instead of OpenSSH `-o` directives |
| BusyBox `ssh` | usually yes | limited/partial | Minimal implementation; advanced OpenSSH options may be missing |
| Tectia SSH | yes | differs | Commercial SSH implementation with its own option model |
| libssh frontend tools | varies | varies | Depends on the specific frontend utility using the library |

## Design principles

- To support more advanced setups beyond the core connection parameters, the wrapper should allow arbitrary SSH options to be passed through unchanged.
- The implementation should remain as simple as practical while preserving compatibility with older Bash and POSIX `sh` environments where possible.
- The code should remain modular enough that optional functionality may be removed without breaking the basic connection workflow when the expected usage is simple.

Although these examples are primarily oriented toward OpenSSH behavior, the
overall approach may later be extended to support other SSH client
implementations.

Different variants of the wrapper may exist for different environments, usage
models, and SSH client implementations.

## Architecture overview

```text
raw input
  -> tokenization
  -> normalization
  -> SSH option extraction
  -> validation
  -> command assembly
  -> multiplex probing
  -> execution
```

## Precedence (OpenSSH-like resolution behavior)

Multiple sources can specify `User` and `Port`: URI-like targets
(`user@host[:port]`), command-line options (`-l`, `-p`, `-o ...`),
wrapper-provided defaults (environment variables), and `~/.ssh/config`.

In OpenSSH, argument order matters: when equivalent connection parameters are
provided multiple ways on the command line, the first specified value becomes
the effective one.

This applies across a mix of syntaxes (for example, `host:port` vs `-p`, or
`user@host` vs `-l` / `-o User=...`).

To match OpenSSH behavior, the wrapper should follow this policy:

- first explicit CLI occurrence wins among equivalent parameters (`User`, `Port`, etc.)
- `~/.ssh/config` defaults apply only if no explicit CLI/target value was given
- wrapper defaults should behave like config defaults (low priority and easy to override)

Examples (port):

```bash
ssh thehost:25 -p 22
```

Effective port should be `25` (the `:25` appears first).

```bash
ssh -p 22 thehost:25
```

Effective port should be `22` (the `-p 22` appears first).

Example (user):

```bash
SSH_USER=deploy ssh -o User=root ssh://nexus@the.h.o.st
```

Effective user should be `root` (the first explicit user-setting on the CLI
wins).

## OpenSSH behavior considerations

One of the primary goals is SSH connection multiplexing. The implementation
relies on the OpenSSH `ControlMaster` functionality, introduced in OpenSSH 3.9
(2004), and uses it by default to reduce connection setup overhead during
repeated SSH operations against the same target.

OpenSSH resolves parameters from multiple sources: command-line options,
URI-style targets, wrapper-provided defaults, and configuration files.

For many parameters, the first explicit value becomes the effective one.

For example:

```bash
ssh -o User=root ssh://nexus@the.h.o.st
```

will use `root` as the effective remote user instead of `nexus`.

This behavior is implementation-specific and should not be treated as a generic
SSH protocol rule.

Starting from OpenSSH 6.8, released in March 2015, the `-G` option became
available.

The `-G` flag prints the fully resolved runtime SSH configuration after
processing. This significantly simplifies validation, debugging, and
precondition checks before attempting a real connection.

### Delegating Final Option Interpretation to OpenSSH

Some wrapper variants included in this script intentionally delegate the final
interpretation of SSH configuration and command-line semantics to OpenSSH
itself via `ssh -G`.

Although these wrappers may perform preliminary parsing, normalization, or
sanity validation, they intentionally avoid attempting to fully reimplement
OpenSSH parsing rules in Bash.

This helps avoid long-term maintenance complexity and behavioral inconsistencies
across OpenSSH versions, configuration combinations, and client-specific
features.

In these variants, the wrapper focuses primarily on:

- early sanity checking,
- argument normalization,
- option extraction,
- safe command assembly,
- multiplexed connection handling,

while OpenSSH itself remains the authoritative parser for SSH-specific
semantics.

## Example goals of the wrapper

Typical wrapper responsibilities may include:

- establishing or reusing multiplexed connections,
- validating SSH arguments before execution,
- normalizing host specifications,
- simplifying repetitive SSH usage,
- passing arbitrary OpenSSH options safely,
- preparing reusable SSH command arrays,
- supporting simple and advanced usage patterns,
- minimizing repeated connection overhead during automation tasks.

The implementation intentionally favors readability and modularity over
excessive abstraction.