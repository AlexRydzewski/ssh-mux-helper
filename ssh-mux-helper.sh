#!/usr/bin/env bash
#
# ssh-mux-helper — Bash helpers for OpenSSH-centric workflows: argument parsing,
# option validation, multiplexed connections (ControlMaster / ControlPath), and
# related utilities. See ssh-mux-helper.md for full documentation.
#
VERSION="0.3.0"
# Author:    Alexander Rydzewski <rydzewski.al@gmail.com>
# License:   MIT — see the LICENSE file in this repository (SPDX-License-Identifier: MIT)

# 1. Define the global essential configuration and constants.
readonly PROG_NAME="$(basename -- "$0")"
readonly PID=$$

# When `take-care-of-the-ssh-host` is listed, parsed host specs are appended to ssh_options_.
: "${OPTION_[@]:=take-care-of-the-ssh-host}"

# 2. Setup journaling and event treatment.

# 2.1. Define the event control function.
: "${TOLERANCE:=3}" "${VERBOSITY:=5}"

__event_control() { # Source: https://github.com/AlexRydzewski/bash-event-logger
    # Second argument = event level when omitted defaults to ${TOLERANCE:-3} (not a fixed 3): higher
    # TOLERANCE raises that default, i.e. looser handling. Level 0: stop but exit 0 (special case).

    #      Debug        |        Info       |         Warning           |           Error           | Silent    
    #---------------------------------------------------------------------------------------------------------------------
    #   Success, vars   | About performing  | If something is wrong but | If something is wrong and | Exit with zero status
    #                   | normal operations | continuation is possible  | stops the execution       | no output
    #---------------------------------------------------------------------------------------------------------------------
    #      9 | 8        |  7  |   6   |  5  |          4 | 3            |           2 | 1           |   0

    # Typically:
    # 2,3 - critical errors without the ability to continue
    # 4,5 - warnings or non-fatal errors that allow the script to continue
    # 6 - messages at the beginning of the function
    # 7 - messages at the beginning of the operation
    # 8 - about successful execution
    # 9 - something unnecessary

    # If event level is above VERBOSITY, suppress; if below TOLERANCE floor, skip acting (return) or exit.
    [[ ${2:-${TOLERANCE:-3}} -eq 0 ]] && local status=0
    [[ ${2:-5} -gt ${VERBOSITY:-5} ]] && { [[ ${2:-3} -ge ${TOLERANCE:-3} ]] && return; exit; }

    [[ -n "${LOG_FILE:-}" ]] &&
      { [[ -d "$(dirname -- "$LOG_FILE")" ]] ||
            if [[ ${TOLERANCE:-3} -ge 3 ]]; then
                mkdir -p "$(dirname -- "$LOG_FILE")" || { local error_message="Cannot create directory '$(dirname -- "$LOG_FILE")'"; false; }
            else
                local error_message="Directory '$(dirname -- "$LOG_FILE")' doesn't exist"; false
            fi &&
                # : The POSIX "null" builtin - a no-op that simply returns exit status 0.
                # We need some command to attach redirection to; : is the lightest possible.
                ( umask 077 && : >>"$LOG_FILE" ) || { local error_message="Cannot write to '$LOG_FILE'"; false; } ||
                  { if [[ -t 1 ]]; then printf '%s\n' "$(date "+%b %d %H:%M:%S") [$PID]: $error_message"
                    else logger ${logger_opts:-"--tag=${PROG_NAME}[$PID]"} "${message_prefix}$error_message"; fi
                    [[ ${2:-3} -lt ${TOLERANCE:-3} ]] && exit 1; unset LOG_FILE; return; }

        echo "$(date "+%b %d %H:%M:%S") ${HOSTNAME:-localhost} ${PROG_NAME}[$PID]: $1" >> "$LOG_FILE"
        [[ ${2:-3} -ge ${TOLERANCE:-3} ]] && return; exit $status; }

    # Interactive TTY with no LOG_FILE -> send logs to stderr to keep stdout clean and useful.
    [[ -t 1 ]] && { printf '%s\n' "$(date "+%b %d %H:%M:%S") [$PID]: $1" 1>&2; [[ ${2:-3} -ge ${TOLERANCE:-3} ]] && return; exit $status; }
     logger ${logger_opts:-"--tag=${PROG_NAME}[$PID]"} "$message_prefix$1"; [[ ${2:-3} -ge ${TOLERANCE:-3} ]] && return; exit $status
}

# 2.2. Tune message format for logger.

# It worth to consider using uid as alternative to WHOAMI for logger_opts and other purposes.
WHOAMI=$(id -un 2>/dev/null || echo unknown)

# Here message_prefix and logger_opts unset explicitly to avoid accidental reuse of parent shells.
[[ "$(printf '%s\n' "2.27.0" "$(logger --version 2>/dev/null | grep -Eo '[0-9.]+' || echo 0)" | sort -V | head -n1)" = "2.27.0" ]] &&
    if [[ "${WHOAMI}" = "root" ]]; then logger_opts="--id=$PID --tag=$PROG_NAME"; unset message_prefix;
    else message_prefix="($PID) "; unset logger_opts; fi

# 3. Define the SSH utilities and related functions.
# 3.1. Check presence of the SSH utility.
command -v ssh &> /dev/null || { __event_control "SSH utility is not installed" 0; exit 1; }

# 3.2. Check whether the SSH utility is OpenSSH-compatible.
__validate_openssh () {
    local ssh_utility

    if (( $# == 0 )); then
        __event_control "SSH command is not specified. Try just 'ssh'"
        ssh_utility=$(command -v ssh 2>/dev/null) ||
          { __event_control "SSH utility is not installed" 3; return 1; }
    else
        [[ ! -f "$1" ]] &&
          { [[ "$1" != "$(basename -- "$1")" ]] &&
              { __event_control "The '$1' utility does not exist." 3; return 1; }
            ssh_utility=$(command -v -- "$1" 2>/dev/null) ||
              { __event_control "The '$1' utility is not installed" 3; return 1; }; }
    fi
    
    [[ -x "${ssh_utility:-$1}" ]] ||
        { __event_control "The '${ssh_utility:-$1}' utility is not executable." 3; return 1; }

    "${ssh_utility:-$1}" -V 2>&1 | grep -q 'OpenSSH_' && return 0

    __event_control "Unsupported SSH command: '${ssh_utility:-$1}'. Must be OpenSSH compatible." 4
    return 1
}

# 3.3. Define the SSH wrapper functions.

__ssh_simple_simple () {
    # This is the simplest wrapper variant. It expects all arguments and
    # environment variables to be validated before use.
    #
    # For simplicity, the SSH command is assembled as a plain string. Because of
    # this, the function is intended only for trusted, operator-provided input.
    #
    # This implementation intentionally avoids complex shell syntax handling.
    # Values containing shell-special characters, nested quoting, substitutions,
    # or multiline constructs may break parsing or execution semantics.
    # The echoed command has the same limitations.
    #
    # The function primarily exists to establish or reuse an OpenSSH multiplexed
    # connection. It relies on OpenSSH-specific features such as ControlMaster,
    # ControlPath, and `ssh -O check`.

    # The user is specified with `-o User=$SSH_USER` because OpenSSH `scp`
    # supports it as well, allowing the same option handling to be reused.

    local SSH="$@ -o ControlPath=${SSH_CONTROL_PATH:-~/.ssh/%r@%h:%p} \
      -o LogLevel=${SSH_LOG_LEVEL:-quiet} ${SSH_USER:+"-o User=$SSH_USER"} \
      ${SSH_HOST:+"$SSH_HOST"} ${SSH_PORT:+" -p $SSH_PORT"}"
    ssh $SSH -O check &> /dev/null && { echo "${SSH}"; return; }
    
    ssh $SSH -o BatchMode=yes -o ControlMaster=yes -o ControlPersist=1m -o ConnectTimeout=3 \
      -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o PubkeyAuthentication=yes 'exit' \
        || return 1
    echo "ssh ${SSH}"
}

__scp_simple_simple () {
    local SSH="$@ -o ControlPath=${SSH_CONTROL_PATH:-~/.ssh/%r@%h:%p} \
      -o LogLevel=${SSH_LOG_LEVEL:-quiet} ${SSH_USER:+"-o User=$SSH_USER"} \
      ${SSH_HOST:+"$SSH_HOST"} ${SSH_PORT:+" -p $SSH_PORT"}"
    ssh $SSH -O check &> /dev/null && { echo "${SSH}"; return; }
    
    ssh $SSH -o BatchMode=yes -o ControlMaster=yes -o ControlPersist=1m -o ConnectTimeout=3 \
      -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o PubkeyAuthentication=yes 'exit' \
        || return 1
    echo "scp -r -3 ${SSH}"
}

__prepare_argv () {
    # Convert a raw shell-like string into a Bash array while preserving simple
    # quoting semantics.

    # The function parses a single input string character-by-character and appends
    # resulting arguments into the global `argv_` array.

    # It is intentionally minimal and restrictive. The parser is designed for simple,
    # trusted command-line style input and does not attempt to fully implement POSIX
    # shell parsing rules.

    # The function is primarily intended for:

    # - converting simple textual argument definitions into Bash arrays,
    # - preserving quoted substrings containing spaces,
    # - splitting command-like strings into positional arguments,
    # - preparing arguments for later safe array-based execution.

    # Example:
    # local -a argv_=()
    # __prepare_argv 'ssh -o "User root" "host name"'
    # declare -p argv_
    # declare -a argv_=( [0]="ssh" [1]="-o" [2]="User root" [3]="host name" )

    argv_=()
    local token= qch= esc= i c
    local raw="$1"
    for ((i=0; i<${#raw}; i++)); do
        c=${raw:i:1}
        [[ "$c" =~ [[:cntrl:]] ]] && return 1

        (( esc == 1 )) && { token+="$c"; esc=0; continue; }
        [[ -n "$qch" ]] &&
          { [[ "$c" == "$qch" ]] && { qch=; continue; };
            [[ "$qch" == '"' && "$c" == "\\" ]] && { esc=1; continue; }
            [[ "$qch" == '"' && ( "$c" == '$' || "$c" == '`' ) ]] && return 1
            token+="$c"
            continue; }

        case "$c" in
            [[:space:]]) [[ -n "$token" ]] && { argv_+=("$token"); token=; } ;;
            \'|\" )     qch="$c" ;;
            \\)         esc=1 ;;
            *)          token+="$c" ;;
        esac
    done
    (( esc == 1 )) && return 1
    [[ -n "$qch" ]] && return 1
    [[ -n "$token" ]] && argv_+=("$token")

    (( ${#argv_[@]} > 0 ))
}

__ssh_simple () {
    # Allow SSH arguments to be provided either as one raw string per "$1"
    # (split by `__prepare_argv`) or as normal positional arguments.
    # This wrapper relies on OpenSSH-specific features: ControlMaster/ControlPath,
    # `ssh -O check` for multiplex status, and `ssh -G` for argument validation.
    # Do not echo the command here; keep the assembled `ssh_cmd_` array to preserve
    # quoting, whitespace, and argument boundaries exactly.
 
    (($# > 0)) &&
      { local -a argv_ argv_reassembled_
        while [[ $# -gt 0 ]]; do
            # Reassemble each parsed argument vector back into a single normalized string.
            # `${argv_[*]}` is intentionally used here instead of `${argv_[@]}` because
            # the next processing stage expects one normalized shell-like argument string
            # per original positional parameter.
            argv_=(); __prepare_argv "$1" || return 1
            argv_reassembled_+=("${argv_[*]}"); shift
        done
        set -- "${argv_reassembled_[@]}"; unset argv_ argv_reassembled_; }
    
    local ssh_host
    ssh_host=$(ssh -G "$@" ${SSH_USER:+-o "User=$SSH_USER"} \
      ${SSH_PORT:+-o "Port=$SSH_PORT"} dummyhost 2> /dev/null | grep "^host ") \
        || return 1

    ssh_cmd_=(
      ssh "$@"
      -o "ControlPath=${SSH_CONTROL_PATH:-~/.ssh/%r@%h:%p}" -o "LogLevel=quiet")
      [[ -n ${SSH_USER:-} ]] && ssh_cmd_+=(-o "User=$SSH_USER")
      [[ -n ${SSH_PORT:-} ]] && ssh_cmd_+=(-o "Port=$SSH_PORT")
      [[ ${ssh_host} == "host dummyhost" ]] &&
        if [[ -n ${SSH_HOST:-} ]]; then ssh_cmd_+=("$SSH_HOST"); else return 1; fi
    
    "${ssh_cmd_[@]}" -O check &> /dev/null && return
    
    "${ssh_cmd_[@]}" -o BatchMode=yes -o ControlMaster=yes -o ControlPersist=1m -o ConnectTimeout=3 \
      -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o PubkeyAuthentication=yes 'exit' \
        || return 1
}

__normalize_options () {
    # Source idea from:
    #   https://github.com/e36freak/templates/blob/master/options
    #
    # Iterate over options, breaking -ab into -a -b and --foo=bar into --foo bar
    # also turns -- into --endopts to avoid issues with things like '-o-', the '-'
    # should not indicate the end of options, but be an invalid option (or the
    # argument to the option, such as wget -qO-)
    # @todo: Map the expanded options so we can later locate a substring of the original argument when reporting errors
    
    # Keep `argv_`? and `optstring` controlled within the function where this is invoked.
    argv_=()
    # optstring="p:l:i:F:E:J:S:b:c:D:e:L:m:O:Q:R:W:w:" # This for OpenSSH
    while (( $# )); do
        case $1 in
            -[!-]?*)        # If option is of type -ab)
                # Loop over each character starting with the second
                for ((i=1; i < ${#1}; i++)); do
                    # Remember that numeric short options may exist too like the '-3` in scp.
                    c=${1:i:1}; [[ "$c" =~ [^a-zA-Z0-9] ]] &&
                        __event_control "Unsupported character in option: -$c" 1
                    argv_+=("-$c")    # Add current char to options
                    # If option takes a required normalized_job_argv, and it's not the last char make
                    # the rest of the string its normalized_job_argv
                    [[ $optstring = *"$c:"* && ${1:i+1} ]] && { argv_+=("${1:i+1}"); break; }
                done ;;
            # If an option is of the type --foo=bar, split it into --foo bar
            --?*=*) argv_+=("${1%%=*}" "${1#*=}") ;;
            --)     argv_+=(--endopts) ;;   # add --endopts for --;
            *)      argv_+=("$1") ;;        # Otherwise, nothing special
        esac
        shift
    done

    return 0
}

# - Network address regex patterns (POSIX ERE). Simplified practical validation patterns.
#
# These regexes are intentionally not full RFC-compliant parsers.
# Full compliance for IP addresses, DNS names, and URI-like host specifications
# is difficult to express safely and readably in Bash regex alone.
#
# The purpose here is only early sanity checking of operator-provided input:
# reject clearly malformed values before passing them further.
#
# Final interpretation must still be delegated to the tool that actually owns
# the grammar, for example OpenSSH itself via `ssh -G`, or to system/network
# parsers such as `getent`, `inet_pton(3)`, or Python's `ipaddress` module.
readonly RE_IPV4='((25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])'
readonly RE_PORT='(0|[1-9][0-9]{0,3}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5])'
readonly RE_IPV6='\[?([a-fA-F0-9]{1,4}:){1,7}((:[a-fA-F0-9]{1,4})|:){1,6}\]?|([a-fA-F0-9]{1,4}:){7}[a-fA-F0-9]{1,4}|:(:[a-fA-F0-9]{1,7})\]?'  
# Reflect the constraints from RFC 1035 (and later clarifications like RFC 1123).
readonly RE_DOMAIN='([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}'
readonly RE_NET_ADDR="(${RE_IPV4}|${RE_IPV6}|${RE_DOMAIN})(:${RE_PORT})?"
readonly RE_URL="([a-zA-Z][a-zA-Z0-9+.-]*://)?([a-zA-Z0-9._-]+@)?($RE_NET_ADDR)"

# Optional example of an additional validation layer.
__sanitize_argv () {
    [[ "$1" == *$'\n'* || "$1" == *$'\r'* ]] &&
      { __event_control "Invalid SSH option '$1': contains newline" 1; return 1; }
    [[ "$1" =~ [$'\001'-$'\037'$'\177'] ]] &&
      { __event_control "Invalid SSH option '$1': contains control characters" 4; return 1; }
    [[ "$1" =~ [\`\;\&\|\<\>\(\)\{\}] ]] &&
      { __event_control "Invalid SSH option '$1': forbidden shell metacharacters" 4; return 1; }
}

__option_take_care_of_ssh_host () {
    local o
    for o in "${OPTION_[@]}"; do
        [[ "$o" == take-care-of-the-ssh-host ]] && return 0
    done
    return 1
}

__append_ssh_host_if_needed () {
    local host="${1:-}"
    __option_take_care_of_ssh_host || return 0
    [[ -n "$host" ]] || return 1
    ssh_options_+=("$host")
    return 0
}

__build_openssh_options () {
    # This implementation relies on OpenSSH semantics.
    #
    # As an additional safeguard, SSH options are validated at the input stage,
    # and appropriate warnings are issued to the operator or written to the log.
    #
    # Parsing stops as soon as SSH options end or a non-SSH argument is encountered.
    # Remaining arguments are preserved in the `argv_leftover_` array so they may be
    # processed later by another parser or execution layer
    (( $# == 0 )) && __event_control "SSH options are not specified" 4 && return 1
    
    ssh_options_=()
    
    local option
    local optstring="p:l:i:F:E:J:S:b:c:D:e:L:m:O:Q:R:W:w:"
    
    # For normal case this function can check if host is specified and return status accordingly.
    # However, this also takes into account cases where the operator specifies SSH options multiple
    # times and expects them to be assembled into a single command.
    __option_take_care_of_ssh_host && local ssh_host

    while (( $# )); do        
        argv_=()
        __prepare_argv "$1" && __normalize_options "${argv_[@]}" &&
          { for (( i=0; i<${#argv_[@]}; i++ )); do
                # This may be necessary in other contexts. Here we check input when __prepare_argv is used.
                # __sanitize_argv "${argv_[i]}" || return 1
        
                case "${argv_[i]}" in
                    # Flags without value
                    -4|-6|-A|-a|-C|-f|-G|-g|-K|-k|-M|-N|-n|-q|-s|-T|-t|-v|-vv|-vvv|-V|-X|-x|-Y|-y)
                        ssh_options_+=("${argv_[i]}"); continue ;;
                    
                    -o) [[ -z "${argv_[i+1]:-}" ]] &&
                          { (( $# == 0 )) &&
                              { __event_control "SSH option '${argv_[i]}' expects a value" 4
                                argv_leftover_=("$@"); return 1; }
                            option="${argv_[i]}"; break; }

                        # This may be necessary in other contexts. Here we check input when __prepare_argv is used.
                        # __sanitize_argv "${argv_[i+1]}" || return 1
                        [[ "${argv_[i+1]}" =~ ^[A-Za-z][A-Za-z0-9]+(=.*)?$ ]] ||
                          { __event_control "Invalid SSH -o value '${argv_[i+1]}'" 4
                            argv_leftover_=("$@"); return 1; }
                        ssh_options_+=("${argv_[i]}" "${argv_[i+1]}"); (( i++ )); continue ;;

                    -p) [[ -z "${argv_[i+1]:-}" ]] &&
                          { (( $# == 0 )) &&
                              { __event_control "SSH option '${argv_[i]}' expects a value" 4
                                argv_leftover_=("$@"); return 1; }
                            option="${argv_[i]}"; break; }

                        # This may be necessary in other contexts. Here we check input when __prepare_argv is used.
                        # __sanitize_argv "${argv_[i+1]}" || return 1
                        [[ "${argv_[i+1]}" =~ ^${RE_PORT}$ ]] ||
                          { __event_control "SSH port must be integer in 1-65535 range. Given '${argv_[i+1]}'" 4
                            argv_leftover_=("$@"); return 1; }
                        ssh_options_+=("${argv_[i]}" "${argv_[i+1]}"); (( i++ )); continue ;;

                    -l) [[ -z "${argv_[i+1]:-}" ]] &&
                          { (( $# == 0 )) &&
                              { __event_control "SSH option '${argv_[i]}' expects a value" 4
                                argv_leftover_=("$@"); return 1; }
                            option="${argv_[i]}"; break; }
                        
                        # This may be necessary in other contexts. Here we check input when __prepare_argv is used.
                        # __sanitize_argv "${argv_[i+1]}" || return 1
                        [[ "${argv_[i+1]}" =~ ^${RE_LINUX_USERNAME}$ ]] ||
                          { __event_control "Invalid SSH user '${argv_[i+1]}'" 4
                            argv_leftover_=("$@"); return 1; }
                        ssh_options_+=("${argv_[i]}" "${argv_[i+1]}"); (( i++ )); continue ;;

                    -i|-F|-E|-J|-S|-b|-c|-D|-e|-L|-m|-O|-Q|-R|-W|-w)
                        [[ -z "${argv_[i+1]:-}" ]] &&
                          { (( $# == 0 )) &&
                              { __event_control "SSH option '${argv_[i]}' expects a value" 4
                                argv_leftover_=("$@"); return 1; }
                            option="${argv_[i]}"; break; }
                        # This may be necessary in other contexts. Here we check input when __prepare_argv is used.
                        # __sanitize_argv "${argv_[i+1]}" || return 1

                        ssh_options_+=("${argv_[i]}" "${argv_[i+1]}"); (( i++ )); continue ;;

                    --|--endopts)
                        # argv_leftover_: remaining outer positional parameters after this raw chunk.
                        shift; argv_leftover_=("$@")
                        __append_ssh_host_if_needed "${ssh_host:-}" || return 1
                        return 0 ;;

                    -*)  __event_control "Unknown SSH option '${argv_[i]}'. Treat as end of SSH options." 7
                        argv_leftover_=("$@")
                        __append_ssh_host_if_needed "${ssh_host:-}" || return 1
                        return 0 ;;

                    *)  [[ "${option:-}" == "-o" ]] &&
                          { [[ "${argv_[i]}" =~ ^[A-Za-z][A-Za-z0-9]+(=.*)?$ ]] &&
                              { ssh_options_+=("${option}" "${argv_[i]}"); option=""; continue; }
                            __event_control "Invalid SSH -o value '${argv_[i]}'" 4
                            argv_leftover_=("$@"); return 1; }
                        [[ "${option:-}" == "-p" ]] &&
                          { [[ "${argv_[i]}" =~ ^${RE_PORT}$ ]] &&
                              { ssh_options_+=("${option}" "${argv_[i]}"); option=""; continue; }
                            __event_control "SSH port must be integer in 1-65535 range. Given '${argv_[i]}'" 4
                            argv_leftover_=("$@"); return 1; }
                        [[ "${option:-}" == "-l" ]] &&
                          { [[ "${argv_[i]}" =~ ^${RE_LINUX_USERNAME}$ ]] &&
                              { ssh_options_+=("${option}" "${argv_[i]}"); option=""; continue; }
                            __event_control "Invalid SSH user '${argv_[i]}'" 4
                            argv_leftover_=("$@"); return 1; }

                        __event_control "Free argument '${argv_[i]}' found. Check whether it can be interpreted as a host specification." 8
                        [[ "${argv_[i]}" =~ ^${RE_URL}$ ]] &&
                          { # Here need to check if host is already in ssh_options_ because reiterating this
                            # one will break connection.
                            [[ -n "${ssh_host:-}" ]] &&
                              { __event_control "Host '${argv_[i]}' already specified in SSH options. Treat as end of SSH options." 8
                                __append_ssh_host_if_needed "${ssh_host}" || return 1
                                argv_leftover_=("$@"); return 0; }
                            ssh_host="${argv_[i]}"; continue; } ;;                        
                esac
            done
            shift; }
    done
    argv_leftover_=("$@")
    __append_ssh_host_if_needed "${ssh_host:-}" || return 1
    return 0
}

__ssh () {
    # Allow SSH arguments to be provided either as one raw string per argument
    # (parsed by `__raw_to_argv`) or as already separated positional arguments.
    #
    # This wrapper still relies on OpenSSH-specific multiplexing features:
    # ControlMaster, ControlPath, and `ssh -O check` for checking master connection
    # status.
    #
    # However, argument compilation and validation are not tied directly to
    # `ssh -G`. Instead, they are delegated to `__build_openssh_options`. This keeps
    # the wrapper more flexible: another builder/validator may be used later for
    # different OpenSSH versions or even for another SSH client implementation.
    #
    # The goal of this approach is to allow the relevant SSH options to be
    # extracted from a wider generic argument list.
    #
    # Do not echo the assembled command here. Keep it in the `ssh_cmd_` array so
    # quoting, whitespace, and argument boundaries are preserved exactly.

    local -a ssh_options_=()

    __build_openssh_options "$@" || return 1

    ssh_cmd_=(
      ssh "${ssh_options_[@]}"
      -o "ControlPath=${SSH_CONTROL_PATH:-~/.ssh/%r@%h:%p}" -o "LogLevel=quiet")
      [[ -n ${SSH_USER:-} ]] && ssh_cmd_+=(-o "User=$SSH_USER")
      [[ -n ${SSH_PORT:-} ]] && ssh_cmd_+=(-o "Port=$SSH_PORT")

    "${ssh_cmd_[@]}" -O check &> /dev/null && return
    
    "${ssh_cmd_[@]}" -o BatchMode=yes -o ControlMaster=yes -o ControlPersist=1m -o ConnectTimeout=3 \
      -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o PubkeyAuthentication=yes 'exit' \
        || return 1
}

# 4. Define the optional helper functions.
ssh_opts_=("$@")
# Optional helper: run the last assembled command (`ssh_cmd_` is an array).
#__SSH () { SSH=$(__ssh_simple_simple $ssh_opts_) || return 1; "${SSH}" "$@"; }
#__SSH () { __ssh_simple "${ssh_opts_[@]}" || return 1; "${ssh_cmd_[@]}" "$@"; }
__SSH () { __ssh "${ssh_opts_[@]}" || return 1; "${ssh_cmd_[@]}" "$@"; }

# 5. Execution examples.
#SSH=$(__ssh_simple_simple "${ssh_opts_[@]}") || exit; $SSH "echo hello"; $SSH "echo true"
#__ssh_simple "${ssh_opts_[@]}" || exit; "${ssh_cmd_[@]}" "echo hello"; "${ssh_cmd_[@]}" "echo true"
#__ssh "${ssh_opts_[@]}" || exit; "${ssh_cmd_[@]}" "echo hello"; "${ssh_cmd_[@]}" "echo true";
#__validate_openssh "ssh" || exit 1
#__SSH "echo hello"; __SSH "echo true"