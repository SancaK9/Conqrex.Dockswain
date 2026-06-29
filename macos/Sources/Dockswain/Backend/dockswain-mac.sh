#!/usr/bin/env bash
#
# dockswain-mac.sh: the macOS port of the Linux plasmoid's dockswain.sh.
#
# It runs docker commands on a remote host over SSH and prints normalized output
# that the SwiftUI app parses. Auth is either an SSH key (BatchMode, no prompt) or
# a password fed in via the SSHPASS env var (set by the Swift side from Keychain)
# and consumed by `sshpass -e`. A persistent SSH master (ControlPersist) is reused
# so repeated polls/actions return in milliseconds.
#
# Differences from the Linux original, all to stay within BSD/macOS userland:
#   * No `secret-tool` / KWallet  -> the Swift app holds secrets in the macOS
#     Keychain and passes the password through SSHPASS; this script never touches
#     a keyring or a config file.
#   * No `find -printf` / `stat -c` / `df -B` / `setsid` (BSD tools differ); the
#     subcommands that needed them (sftp file-manager, disk usage, remote edit)
#     are not ported in this MVP.
#   * Terminals/editors open in Terminal.app instead of Konsole/Kate.
#
# Usage:
#   dockswain-mac.sh <sub> <user@host> <port> <keyOrEmpty> [args...]
#       sub = probe | list | stats | compose | action | compose-action | logs
#           | exec-cmd | ssh-cmd
#
# Env (set by the app): CNQ_DOCKER_CMD (default "docker"), CNQ_SSH_TIMEOUT (5),
#   CNQ_AUTH ("key" | "password"), SSHPASS (when CNQ_AUTH=password).
#
# Output:
#   * list / stats  -> the raw `docker ... --format '{{json .}}'` NDJSON on stdout
#                      (the app parses each line). Errors go to a one-line JSON on
#                      stdout prefixed with the marker @@ERR@@ and a reason code.
#   * everything else -> a single JSON object: {"ok":true,...} or
#                      {"ok":false,"reason":"..."}.

set -u

SUB="${1:-}"; shift || true

DOCKER="${CNQ_DOCKER_CMD:-docker}"

emit_err() { printf '{"ok":false,"reason":"%s"}\n' "$1"; exit 0; }

# ---------------------------------------------------------------------------
# Subcommands that need no SSH target (run on this Mac)
# ---------------------------------------------------------------------------
if [ "$SUB" = "ssh-config-hosts" ]; then
    # Discover candidate hosts from ~/.ssh/config (Host blocks with a HostName).
    CFG="${HOME}/.ssh/config"
    [ -f "$CFG" ] || { printf '{"ok":true,"hosts":[]}\n'; exit 0; }
    awk '
        BEGIN { h=""; hn=""; u=""; p=22; ik="" }
        function flush() {
            if (h != "" && h !~ /[*?]/) {
                printf("%s\t%s\t%s\t%s\t%s\n", h, (hn!=""?hn:h), u, p, ik)
            }
        }
        tolower($1)=="host"     { flush(); h=$2; hn=""; u=""; p=22; ik="" ; next }
        tolower($1)=="hostname" { hn=$2; next }
        tolower($1)=="user"     { u=$2; next }
        tolower($1)=="port"     { p=$2; next }
        tolower($1)=="identityfile" { ik=$2; next }
        END { flush() }
    ' "$CFG" | jq -Rsc '
        split("\n") | map(select(length>0)) | map(split("\t")) |
        map({ label:.[0], host:.[1], user:.[2], port:(.[3]|tonumber? // 22),
              key:(.[4] // "" | sub("^~"; env.HOME)), auth:( if (.[4]//"")!="" then "key" else "key" end) })'
    printf '\n'
    exit 0
fi

# ---------------------------------------------------------------------------
# Everything else needs an SSH target
# ---------------------------------------------------------------------------
TARGET="${1:-}"; PORT="${2:-22}"; KEY="${3:-}"
shift 3 2>/dev/null || true
[ -n "$TARGET" ] || emit_err "no_target"
case "$PORT" in ''|*[!0-9]*) PORT=22 ;; esac

AUTH="${CNQ_AUTH:-key}"

# Control socket lives in the per-user secure $TMPDIR on macOS (no /run/user).
RT="${TMPDIR:-/tmp}"; RT="${RT%/}"

COMMON_OPTS=(
    -o ConnectTimeout="${CNQ_SSH_TIMEOUT:-5}"
    -o ControlMaster=auto
    -o ControlPath="${RT}/cnq-ssh-%r@%h:%p"
    -o ControlPersist=60
    -o ServerAliveInterval=15
    -o ServerAliveCountMax=3
    -o StrictHostKeyChecking=accept-new
    -p "$PORT")

ASKPASS=""
cleanup() { [ -n "$ASKPASS" ] && rm -f "$ASKPASS" 2>/dev/null; }
trap cleanup EXIT

if [ "$AUTH" = "password" ]; then
    [ -n "${SSHPASS:-}" ] || emit_err "no_password"
    # No sshpass needed: OpenSSH's own SSH_ASKPASS feeds the password. With
    # SSH_ASKPASS_REQUIRE=force (OpenSSH 8.4+, macOS ships 9/10), ssh always asks
    # the helper instead of a tty, so this works headless from the app. The helper
    # just echoes $SSHPASS, which is exported here and never on a command line.
    ASKPASS=$(mktemp "${TMPDIR:-/tmp}/cnq-askpass.XXXXXX") || emit_err "tmp_failed"
    printf '#!/bin/sh\nprintf "%%s\\n" "$SSHPASS"\n' > "$ASKPASS"
    chmod 700 "$ASKPASS"
    export SSHPASS
    SSH=(env "SSH_ASKPASS=$ASKPASS" SSH_ASKPASS_REQUIRE=force ssh
        -o NumberOfPasswordPrompts=1
        -o PreferredAuthentications=password
        -o PubkeyAuthentication=no
        "${COMMON_OPTS[@]}")
else
    SSH=(ssh -o BatchMode=yes "${COMMON_OPTS[@]}")
    [ -n "$KEY" ] && SSH+=(-o IdentitiesOnly=yes -i "$KEY")
fi
SSH+=("$TARGET")

SSH_OUT=""; SSH_ERR=""; SSH_RC=0
ssh_exec() {
    local errf; errf=$(mktemp 2>/dev/null) || { SSH_RC=99; return; }
    SSH_OUT=$("${SSH[@]}" "$1" 2>"$errf"); SSH_RC=$?
    SSH_ERR=$(cat "$errf" 2>/dev/null); rm -f "$errf"
}

# classify a non-zero ssh/docker result into a stable reason code
classify() {
    local e="$SSH_ERR"
    if echo "$e" | grep -qiE 'docker daemon socket|cannot connect to the docker daemon'; then
        if echo "$e" | grep -qiE 'permission denied'; then echo "docker_permission"; else echo "docker_down"; fi
    elif echo "$e" | grep -qiE 'docker: command not found|not found'; then echo "docker_missing"
    elif echo "$e" | grep -qiE 'permission denied \(|publickey|password|authenticat'; then echo "ssh_auth"
    elif echo "$e" | grep -qiE 'could not resolve|name or service not known'; then echo "dns"
    elif echo "$e" | grep -qiE 'connection refused'; then echo "refused"
    elif echo "$e" | grep -qiE 'timed out|timeout'; then echo "timeout"
    elif echo "$e" | grep -qiE 'no route to host|network is unreachable'; then echo "unreachable"
    else echo "ssh_error"; fi
}

# single-quote-escape a value for safe embedding in a remote single-quoted string
rsq() { local _q="'\\''"; printf '%s' "${1//\'/$_q}"; }

case "$SUB" in

probe)
    ssh_exec "$DOCKER version --format '{{.Server.Version}}'"
    if [ "$SSH_RC" -eq 0 ]; then
        ver=$(printf '%s' "$SSH_OUT" | tr -d '\r\n' | head -c 40)
        printf '{"ok":true,"reachable":true,"dockerOk":true,"version":"%s"}\n' "$ver"
    else
        reason=$(classify)
        reachable=true
        case "$reason" in ssh_auth|dns|refused|timeout|unreachable|ssh_error) reachable=false;; esac
        printf '{"ok":false,"reachable":%s,"dockerOk":false,"reason":"%s"}\n' "$reachable" "$reason"
    fi
    ;;

# list / stats stream the raw docker NDJSON; the Swift side decodes each line.
# On error, a single marker line so the app can show a reason instead of an empty list.
list)
    ssh_exec "$DOCKER ps -a --no-trunc --format '{{json .}}'"
    if [ "$SSH_RC" -ne 0 ]; then printf '@@ERR@@ %s\n' "$(classify)"; exit 0; fi
    printf '%s\n' "$SSH_OUT"
    ;;

stats)
    ssh_exec "$DOCKER stats --no-stream --format '{{json .}}'"
    if [ "$SSH_RC" -ne 0 ]; then printf '@@ERR@@ %s\n' "$(classify)"; exit 0; fi
    printf '%s\n' "$SSH_OUT"
    ;;

compose)
    ssh_exec "$DOCKER compose ls -a --format json"
    if [ "$SSH_RC" -ne 0 ]; then emit_err "$(classify)"; fi
    [ -n "$SSH_OUT" ] || SSH_OUT="[]"
    printf '{"ok":true,"projects":%s}\n' "$SSH_OUT"
    ;;

action)
    ACT="${1:-}"; ID="${2:-}"
    [ -n "$ID" ] || emit_err "no_id"
    case "$ID" in *[!0-9a-fA-F]*) emit_err "bad_id";; esac
    case "$ACT" in
        start|stop|restart) ssh_exec "$DOCKER $ACT $ID" ;;
        rm)                 ssh_exec "$DOCKER rm -f $ID" ;;
        *) emit_err "bad_action" ;;
    esac
    if [ "$SSH_RC" -eq 0 ]; then
        printf '{"ok":true}\n'
    else
        msg=$(printf '%s' "$SSH_ERR" | tr -d '\r\n"' | head -c 160)
        printf '{"ok":false,"reason":"%s"}\n' "${msg:-action_failed}"
    fi
    ;;

compose-action)
    ACT="${1:-}"; CSV="${2:-}"
    case "$ACT" in up|down) ;; *) emit_err "bad_action";; esac
    [ -n "$CSV" ] || emit_err "no_config"
    fargs=""
    IFS=',' read -ra files <<< "$CSV"
    for f in "${files[@]}"; do
        [ -n "$f" ] || continue
        esc=$(rsq "$f")
        fargs+=" -f '$esc'"
    done
    remote="$DOCKER compose${fargs} $ACT"
    [ "$ACT" = "up" ] && remote+=" -d"
    ssh_exec "$remote"
    if [ "$SSH_RC" -eq 0 ]; then
        printf '{"ok":true}\n'
    else
        msg=$(printf '%s' "$SSH_ERR" | tr -d '\r\n"' | head -c 160)
        printf '{"ok":false,"reason":"%s"}\n' "${msg:-compose_failed}"
    fi
    ;;

logs)
    ID="${1:-}"; TAIL="${2:-200}"
    [ -n "$ID" ] || emit_err "no_id"
    case "$ID" in *[!0-9a-fA-F]*) emit_err "bad_id";; esac
    case "$TAIL" in ''|*[!0-9]*) TAIL=200 ;; esac
    ssh_exec "$DOCKER logs --tail $TAIL $ID 2>&1"
    if [ "$SSH_RC" -ne 0 ] && [ -z "$SSH_OUT" ]; then emit_err "$(classify)"; fi
    # strip ANSI, JSON-encode the body
    text=$(printf '%s' "$SSH_OUT" | sed $'s/\x1b\\[[0-9;]*[mK]//g' | jq -Rsc '.')
    [ -n "$text" ] || text='""'
    printf '{"ok":true,"text":%s}\n' "$text"
    ;;

# ssh-cmd / exec-cmd: print the command line for Terminal.app to run (the Swift
# side hands this to `osascript` to open a window). We only emit the argv as a
# JSON array; the app builds the AppleScript. This keeps interactive TTY work in
# a real terminal, exactly like the Linux build opens Konsole.
# Interactive terminals reuse the SAME warm master socket the poller keeps alive
# (ControlPath below). So even a password server connects with no prompt — the
# master is already authenticated. That's why Terminal.app never needs sshpass.
ssh-cmd)
    args=(-o ControlMaster=auto -o "ControlPath=${RT}/cnq-ssh-%r@%h:%p" -o ControlPersist=60
          -o StrictHostKeyChecking=accept-new -p "$PORT")
    [ "$AUTH" != "password" ] && [ -n "$KEY" ] && args+=(-o IdentitiesOnly=yes -i "$KEY")
    args+=("$TARGET")
    printf '%s\n' "${args[@]}" | jq -Rsc 'split("\n")|map(select(length>0))' \
        | { read -r a; printf '{"ok":true,"argv":%s}\n' "$a"; }
    ;;

exec-cmd)
    ID="${1:-}"; SHELL_BIN="${2:-sh}"
    [ -n "$ID" ] || emit_err "no_id"
    case "$ID" in *[!0-9a-fA-F]*) emit_err "bad_id";; esac
    args=(-t -o ControlMaster=auto -o "ControlPath=${RT}/cnq-ssh-%r@%h:%p" -o ControlPersist=60
          -o StrictHostKeyChecking=accept-new -p "$PORT")
    [ "$AUTH" != "password" ] && [ -n "$KEY" ] && args+=(-o IdentitiesOnly=yes -i "$KEY")
    args+=("$TARGET" "$DOCKER exec -it $ID $SHELL_BIN")
    printf '%s\n' "${args[@]}" | jq -Rsc 'split("\n")|map(select(length>0))' \
        | { read -r a; printf '{"ok":true,"argv":%s}\n' "$a"; }
    ;;

*)
    emit_err "bad_subcommand"
    ;;
esac
