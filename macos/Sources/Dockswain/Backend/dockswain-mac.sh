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
#   * No `sshpass`: password auth uses OpenSSH's own SSH_ASKPASS helper.
#   * The remote is Linux, so `find -printf` / `df -B` / `stat -c` run fine THERE;
#     only the local file-manager pane is listed natively in Swift (BSD find lacks
#     -printf), and detached transfer workers are replaced by plain scp from Swift.
#   * Terminals/editors open in Terminal.app instead of Konsole/Kate.
#
# Usage:
#   dockswain-mac.sh <sub> <user@host> <port> <keyOrEmpty> [args...]
#       sub = probe | list | stats | compose | action | compose-action | logs
#           | exec-cmd | ssh-cmd | disk | prune | container-logs | truncate-log
#           | stack-action | readfile | writefile | sftp-home | sftp-list
#           | sftp-mkdir | sftp-rename | sftp-delete | scp-up | scp-down
#           | nginx-list | nginx-toggle | nginx-test | nginx-reload
#           | certbot-list | certbot-issue
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
# When docker runs via sudo, mirror that for root-owned filesystem reads/writes
# (container log files, /etc/nginx, certbot). sudo -n never prompts, so a missing
# NOPASSWD rule fails fast. With a bare `docker` we run unprivileged.
case "$DOCKER" in "sudo "*|sudo) SUDO="sudo -n" ;; *) SUDO="" ;; esac
NGINX_DIR="${CNQ_NGINX_DIR:-/etc/nginx}"

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
      split("\u0000") | map(select(length>0)) | map(split("\t")) |
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

# JSON-encode an arbitrary string as a JSON string literal
jstr() { printf '%s' "${1-}" | jq -Rsc '.'; }

# Turn a NUL-separated `find ... -printf '%y\t%s\t%T@\t%m\t%f\0'` stream (stdin) into
# the entries JSON array. The remote is Linux, so its find supports -printf; the local
# pane lists files in Swift instead. NUL between records + TAB within keeps odd names intact.
entries_from_find() {
    jq -Rsc '
      split("\u0000") | map(select(length>0)) | map(split("\t")) |
      map({
        name:  (.[4] // ""),
        type:  ( .[0] as $y |
                 if   $y=="d" then "dir"
                 elif $y=="l" then "link"
                 elif $y=="f" then "file"
                 else "other" end ),
        size:  (.[1] // "0" | tonumber? // 0),
        mtime: (.[2] // "0" | sub("\\..*";"") | tonumber? // 0),
        mode:  (.[3] // "")
      })'
}

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

# ---------------------------------------------------------------------------
# Disk usage & cleanup (all run on the remote Linux host, so they port directly)
# ---------------------------------------------------------------------------
disk)
    remote='root=$('"$DOCKER"' info --format "{{.DockerRootDir}}" 2>/dev/null); [ -n "$root" ] || root=/var/lib/docker; df -PB1 "$root" 2>/dev/null | awk '\''NR==2{print $2" "$3" "$4" "$5}'\''; echo "@@DF@@"; '"$DOCKER"' system df --format "{{json .}}" 2>/dev/null'
    ssh_exec "$remote"
    if [ "$SSH_RC" -ne 0 ] && [ -z "$SSH_OUT" ]; then emit_err "$(classify)"; fi
    read -r dsize dused davail dusep <<< "$(printf '%s\n' "$SSH_OUT" | awk '/^@@DF@@/{exit} {print}')"
    sysdf=$(printf '%s\n' "$SSH_OUT" | awk 'f{print} /^@@DF@@/{f=1}' | jq -sc '
        [ .[] | {type:.Type, count:(.TotalCount), active:.Active, size:.Size, reclaimable:.Reclaimable} ]' 2>/dev/null)
    [ -n "$sysdf" ] || sysdf="[]"
    disk=$(jq -nc --arg s "${dsize:-}" --arg u "${dused:-}" --arg a "${davail:-}" --arg p "${dusep:-}" \
        '{size:($s|tonumber? // 0), used:($u|tonumber? // 0), avail:($a|tonumber? // 0), usePct:$p}')
    printf '{"ok":true,"disk":%s,"df":%s}\n' "$disk" "$sysdf"
    ;;

prune)
    WHAT="${1:-}"
    case "$WHAT" in
        builder)    ssh_exec "$DOCKER builder prune -f" ;;
        images)     ssh_exec "$DOCKER image prune -f" ;;
        containers) ssh_exec "$DOCKER container prune -f" ;;
        *) emit_err "bad_prune" ;;
    esac
    if [ "$SSH_RC" -eq 0 ]; then
        recl=$(printf '%s' "$SSH_OUT" | grep -iE 'reclaimed space' | tail -1 | sed -E 's/.*[Rr]eclaimed space:[[:space:]]*//')
        printf '{"ok":true,"reclaimed":%s}\n' "$(printf '%s' "${recl:-0B}" | jq -Rsc '.')"
    else
        msg=$(printf '%s' "$SSH_ERR" | tr -d '\r\n"' | head -c 160)
        printf '{"ok":false,"reason":"%s"}\n' "${msg:-prune_failed}"
    fi
    ;;

container-logs)
    IFS= read -r -d '' remote <<REMOTE || true
ids=\$($DOCKER ps -aq --no-trunc 2>/dev/null)
[ -n "\$ids" ] || exit 0
$DOCKER inspect --format '{{.Id}} {{.Name}} {{.LogPath}}' \$ids 2>/dev/null \
  | while read -r id name lp; do
      sz=-1
      if [ -z "\$lp" ]; then sz=-2
      elif s=\$($SUDO stat -c %s "\$lp" 2>/dev/null); then sz=\$s
      fi
      printf '%s %s %s %s\n' "\$id" "\$name" "\$sz" "\$lp"
    done
REMOTE
    ssh_exec "$remote"
    if [ "$SSH_RC" -ne 0 ] && [ -z "$SSH_OUT" ]; then emit_err "$(classify)"; fi
    logs=$(printf '%s\n' "$SSH_OUT" | jq -R -s -c '
        split("\n") | map(select(length>0)) | map(split(" ")) |
        map({ id:(.[0] // ""), name:((.[1] // "") | ltrimstr("/")),
              size:((.[2] // "0") | tonumber? // 0), path:(.[3] // "") }) |
        sort_by( if .size >= 0 then -(.size) else 1000000000000000 - .size end )' 2>/dev/null)
    [ -n "$logs" ] || logs="[]"
    total=$(printf '%s' "$logs" | jq -c '[ .[] | select(.size >= 0) | .size ] | add // 0' 2>/dev/null)
    [ -n "$total" ] || total=0
    printf '{"ok":true,"logs":%s,"total":%s}\n' "$logs" "$total"
    ;;

truncate-log)
    ID="${1:-}"
    [ -n "$ID" ] || emit_err "no_id"
    case "$ID" in *[!0-9a-fA-F]*) emit_err "bad_id";; esac
    IDe=$(rsq "$ID")
    IFS= read -r -d '' remote <<REMOTE || true
lp=\$($DOCKER inspect --format '{{.LogPath}}' '$IDe' 2>/dev/null)
[ -n "\$lp" ] || { echo NOLOG; exit 0; }
case "\$lp" in *-json.log) ;; *) echo BADPATH; exit 0 ;; esac
if $SUDO truncate -s 0 "\$lp" 2>/dev/null; then echo OK; else echo FAIL; fi
REMOTE
    ssh_exec "$remote"
    if [ "$SSH_RC" -ne 0 ] && [ -z "$SSH_OUT" ]; then emit_err "$(classify)"; fi
    case "$(printf '%s' "$SSH_OUT" | tr -d '\r\n ')" in
        OK)      printf '{"ok":true}\n' ;;
        NOLOG)   emit_err "no_log" ;;
        BADPATH) emit_err "bad_path" ;;
        *)       emit_err "truncate_failed" ;;
    esac
    ;;

stack-action)
    ACT="${1:-}"; NAME="${2:-}"
    [ "$ACT" = "rm" ] || emit_err "bad_action"
    [ -n "$NAME" ] || emit_err "no_name"
    nesc=$(rsq "$NAME")
    ssh_exec "$DOCKER stack rm '$nesc'"
    if [ "$SSH_RC" -eq 0 ]; then printf '{"ok":true}\n'
    else
        msg=$(printf '%s' "$SSH_ERR" | tr -d '\r\n"' | head -c 160)
        printf '{"ok":false,"reason":"%s"}\n' "${msg:-stack_failed}"
    fi
    ;;

# ---------------------------------------------------------------------------
# Read / write a remote file (used by nginx + compose file view/edit). writefile
# takes base64 content as an arg and decodes on the remote (fine for config files).
# ---------------------------------------------------------------------------
readfile)
    P="${1:-}"; [ -n "$P" ] || emit_err "no_path"
    pesc=$(rsq "$P")
    ssh_exec "${SUDO:+$SUDO }cat -- '$pesc'"
    if [ "$SSH_RC" -ne 0 ]; then
        if   echo "$SSH_ERR" | grep -qi 'no such file';      then emit_err "not_found"
        elif echo "$SSH_ERR" | grep -qi 'permission denied'; then emit_err "permission"
        else emit_err "$(classify)"; fi
    fi
    printf '{"ok":true,"path":%s,"text":%s}\n' "$(jstr "$P")" "$(printf '%s' "$SSH_OUT" | jq -Rsc '.')"
    ;;

writefile)
    P="${1:-}"; B64="${2:-}"
    [ -n "$P" ] || emit_err "no_path"
    pesc=$(rsq "$P"); besc=$(rsq "$B64")
    ssh_exec "printf %s '$besc' | base64 -d | ${SUDO:+$SUDO }tee -- '$pesc' >/dev/null 2>&1 && echo OK"
    if [ "$SSH_RC" -eq 0 ] && [ "$(printf '%s' "$SSH_OUT" | tr -d '\r\n ')" = OK ]; then
        printf '{"ok":true}\n'
    elif echo "$SSH_ERR" | grep -qi 'permission denied'; then emit_err "permission"
    else emit_err "write_failed"; fi
    ;;

# ---------------------------------------------------------------------------
# SFTP file manager (remote pane). The local pane is listed in Swift. The remote
# is Linux, so find -printf works there.
# ---------------------------------------------------------------------------
sftp-home)
    ssh_exec 'printf %s "$HOME"'
    if [ "$SSH_RC" -ne 0 ] && [ -z "$SSH_OUT" ]; then emit_err "$(classify)"; fi
    h=$(printf '%s' "$SSH_OUT" | tr -d '\r\n'); [ -n "$h" ] || h="/"
    printf '{"ok":true,"home":%s}\n' "$(jstr "$h")"
    ;;

sftp-list)
    P="${1:-}"; [ -n "$P" ] || emit_err "no_path"
    pesc=$(rsq "$P")
    outf=$(mktemp) || emit_err "tmp_failed"; errf=$(mktemp) || { rm -f "$outf"; emit_err "tmp_failed"; }
    "${SSH[@]}" "find -- '$pesc' -maxdepth 1 -mindepth 1 -printf '%y\t%s\t%T@\t%m\t%f\0'" >"$outf" 2>"$errf"
    rc=$?; SSH_ERR=$(cat "$errf" 2>/dev/null)
    entries=$(entries_from_find < "$outf"); rm -f "$outf" "$errf"
    if [ "$rc" -ne 0 ] && { [ -z "$entries" ] || [ "$entries" = "[]" ]; }; then
        if   echo "$SSH_ERR" | grep -qi 'no such file';      then emit_err "not_found"
        elif echo "$SSH_ERR" | grep -qi 'permission denied'; then emit_err "permission"
        else emit_err "$(classify)"; fi
    fi
    [ -n "$entries" ] || entries="[]"
    printf '{"ok":true,"path":%s,"entries":%s}\n' "$(jstr "$P")" "$entries"
    ;;

sftp-mkdir)
    P="${1:-}"; [ -n "$P" ] || emit_err "no_path"; pesc=$(rsq "$P")
    ssh_exec "mkdir -- '$pesc' 2>&1"
    if [ "$SSH_RC" -eq 0 ]; then printf '{"ok":true}\n'
    elif echo "$SSH_OUT$SSH_ERR" | grep -qi 'file exists';       then emit_err "exists"
    elif echo "$SSH_OUT$SSH_ERR" | grep -qi 'permission denied'; then emit_err "permission"
    else emit_err "mkdir_failed"; fi
    ;;

sftp-rename)
    O="${1:-}"; N="${2:-}"; { [ -n "$O" ] && [ -n "$N" ]; } || emit_err "no_path"
    oesc=$(rsq "$O"); nesc=$(rsq "$N")
    ssh_exec "mv -n -- '$oesc' '$nesc' 2>&1"
    if [ "$SSH_RC" -eq 0 ]; then printf '{"ok":true}\n'
    elif echo "$SSH_OUT$SSH_ERR" | grep -qi 'permission denied'; then emit_err "permission"
    else emit_err "rename_failed"; fi
    ;;

sftp-delete)
    P="${1:-}"; REC="${2:-0}"; [ -n "$P" ] || emit_err "no_path"
    case "$P" in /|""|.|..) emit_err "refused";; esac
    [[ "$REC" =~ ^[01]$ ]] || REC=0; pesc=$(rsq "$P")
    rdel='p=$1; rec=$2
rt=$(readlink -f -- "$p" 2>/dev/null); [ -n "$rt" ] || rt=$p
rt=${rt%/}; [ -n "$rt" ] || rt=/
case "$rt" in
  /|/bin|/boot|/dev|/etc|/home|/lib|/lib32|/lib64|/libx32|/proc|/root|/run|/sbin|/srv|/sys|/usr|/var|"$HOME")
    echo cnq-refused >&2; exit 9 ;;
esac
if [ "$rec" = 1 ]; then rm -r -- "$p"
elif [ -d "$p" ] && [ ! -L "$p" ]; then rmdir -- "$p"
else rm -- "$p"; fi'
    ssh_exec "sh -c '$rdel' _ '$pesc' '$REC'"
    if [ "$SSH_RC" -eq 9 ];                                      then emit_err "refused"
    elif [ "$SSH_RC" -eq 0 ]; then printf '{"ok":true}\n'
    elif echo "$SSH_OUT$SSH_ERR" | grep -qi 'not empty';         then emit_err "not_empty"
    elif echo "$SSH_OUT$SSH_ERR" | grep -qi 'permission denied'; then emit_err "permission"
    else emit_err "delete_failed"; fi
    ;;

# ---------------------------------------------------------------------------
# nginx: browse /etc/nginx, view/edit sites, enable/disable, test, reload.
# ---------------------------------------------------------------------------
# nginx-list: ported 1:1 from the Linux build's nginx-info. Detects the layout
# (sites-available + sites-enabled symlinks, vs conf.d/*.conf with a .disabled twin),
# collects every server_name token (dropping the catch-all '_' and dupes), and flags
# TLS. Emits base + style + one row per vhost.
nginx-list)
    SU="${SUDO:+$SUDO }"
    IFS= read -r -d '' remote <<REMOTE || true
base="$NGINX_DIR"
conf="\$base/nginx.conf"
${SU}test -d "\$base" || { echo "@@NODIR@@"; exit 0; }
style=confd
if ${SU}test -f "\$conf" && ${SU}grep -qE 'sites-enabled' "\$conf" 2>/dev/null; then style=sites
elif ${SU}test -d "\$base/sites-available"; then style=sites; fi
printf 'style=%s\n' "\$style"
printf 'conf=%s\n' "\$(${SU}test -f "\$conf" && echo 1 || echo 0)"
meta() {
  sn=\$(${SU}sed 's/#.*//' "\$1" 2>/dev/null \
        | awk 'tolower(\$1)=="server_name"{for(i=2;i<=NF;i++){t=\$i; sub(/;.*/,"",t); if(t!=""&&t!="_"&&!seen[t]++){printf "%s%s",(n++?" ":""),t}}}')
  s=0; ${SU}sed 's/#.*//' "\$1" 2>/dev/null \
        | grep -aiqE '(^|[[:space:]])ssl_certificate([[:space:]]|;)|listen[^;]*[[:space:]]ssl([[:space:]]|;|\$)' && s=1
  printf '%s\t%s' "\$s" "\$sn"
}
if [ "\$style" = sites ]; then
  for f in "\$base"/sites-available/*; do
    ${SU}test -e "\$f" || continue
    n=\$(basename "\$f")
    if ${SU}test -e "\$base/sites-enabled/\$n"; then en=1; else en=0; fi
    printf 'site\t%s\t%s\t%s\t' "\$n" "\$f" "\$en"; meta "\$f"; printf '\n'
  done
else
  for f in "\$base"/conf.d/*.conf "\$base"/conf.d/*.conf.disabled; do
    ${SU}test -e "\$f" || continue
    b=\$(basename "\$f")
    case "\$b" in
      *.conf.disabled) n="\${b%.disabled}"; ${SU}test -e "\$base/conf.d/\$n" && continue; en=0;;
      *.conf)          n="\$b"; en=1;;
      *) continue;;
    esac
    printf 'site\t%s\t%s\t%s\t' "\$n" "\$f" "\$en"; meta "\$f"; printf '\n'
  done
fi
REMOTE
    ssh_exec "$remote"
    if [ "$SSH_RC" -ne 0 ] && [ -z "$SSH_OUT" ]; then emit_err "$(classify)"; fi
    if printf '%s' "$SSH_OUT" | grep -q '@@NODIR@@'; then emit_err "no_nginx_dir"; fi
    style=$(printf '%s\n' "$SSH_OUT" | sed -n 's/^style=//p' | head -1)
    sites=$(printf '%s\n' "$SSH_OUT" | awk -F'\t' '$1=="site"{printf "%s\t%s\t%s\t%s\t%s\n",$2,$3,$4,$5,$6}' \
        | jq -Rsc 'split("\n")|map(select(length>0))|map(split("\t"))|
            map({name:.[0], path:.[1], enabled:(.[2]=="1"), tls:(.[4]=="1"), serverName:(.[5]//"")})' 2>/dev/null)
    [ -n "$sites" ] || sites="[]"
    printf '{"ok":true,"dir":%s,"style":"%s","sites":%s}\n' "$(jstr "$NGINX_DIR")" "${style:-confd}" "$sites"
    ;;

# nginx-toggle: ported from nginx-site. Handles both layouts — sites-enabled symlink,
# or conf.d/*.conf <-> *.conf.disabled (never overwriting the opposite twin).
nginx-toggle)
    ACT="${1:-}"; BN="${2:-}"
    case "$ACT" in enable|disable) ;; *) emit_err "bad_action";; esac
    [ -n "$BN" ] || emit_err "no_name"
    case "$BN" in */*|..) emit_err "bad_name";; esac
    SU="${SUDO:+$SUDO }"; N=$(rsq "$BN")
    IFS= read -r -d '' remote <<REMOTE || true
base="$NGINX_DIR"; name='$N'; act='$ACT'
name=\$(basename "\$name")
conf="\$base/nginx.conf"
style=confd
if ${SU}test -f "\$conf" && ${SU}grep -qE 'sites-enabled' "\$conf" 2>/dev/null; then style=sites
elif ${SU}test -d "\$base/sites-available"; then style=sites; fi
if [ "\$style" = sites ]; then
  if [ "\$act" = enable ]; then ${SU}ln -sf "../sites-available/\$name" "\$base/sites-enabled/\$name"
  else ${SU}rm -f "\$base/sites-enabled/\$name"; fi
else
  if [ "\$act" = enable ]; then
    ${SU}test -e "\$base/conf.d/\$name" && { echo CONFLICT; exit 0; }
    ${SU}test -f "\$base/conf.d/\$name.disabled" && ${SU}mv "\$base/conf.d/\$name.disabled" "\$base/conf.d/\$name"
  else
    ${SU}test -e "\$base/conf.d/\$name.disabled" && { echo CONFLICT; exit 0; }
    ${SU}test -f "\$base/conf.d/\$name" && ${SU}mv "\$base/conf.d/\$name" "\$base/conf.d/\$name.disabled"
  fi
fi
echo OK
REMOTE
    ssh_exec "$remote"
    case "$(printf '%s' "$SSH_OUT" | tr -d '\r\n ')" in
        *OK)       printf '{"ok":true}\n' ;;
        *CONFLICT) emit_err "conflict" ;;
        *) if echo "$SSH_ERR" | grep -qi 'permission denied'; then emit_err "permission"; else emit_err "toggle_failed"; fi ;;
    esac
    ;;

# nginx-new: write a new server block (built in Swift, passed as base64) to the
# right place — sites-available + symlink if that layout exists, else conf.d/*.conf.
nginx-new)
    NAME="${1:-}"; B64="${2:-}"
    [ -n "$NAME" ] || emit_err "no_name"
    case "$NAME" in *[!A-Za-z0-9._-]*|''|.|..) emit_err "bad_name";; esac
    [ -n "$B64" ] || emit_err "no_content"
    IFS= read -r -d '' remote <<REMOTE || true
nd="$NGINX_DIR"
content=\$(printf %s '$B64' | base64 -d)
if ${SUDO:+$SUDO }test -d "\$nd/sites-available"; then
  printf '%s\n' "\$content" | ${SUDO:+$SUDO }tee "\$nd/sites-available/$NAME" >/dev/null && \
    ${SUDO:+$SUDO }ln -sf "\$nd/sites-available/$NAME" "\$nd/sites-enabled/$NAME" && echo OK
else
  ${SUDO:+$SUDO }mkdir -p "\$nd/conf.d" && \
    printf '%s\n' "\$content" | ${SUDO:+$SUDO }tee "\$nd/conf.d/$NAME.conf" >/dev/null && echo OK
fi
REMOTE
    ssh_exec "$remote"
    if [ "$SSH_RC" -eq 0 ] && printf '%s' "$SSH_OUT" | grep -q OK; then printf '{"ok":true}\n'
    elif echo "$SSH_OUT$SSH_ERR" | grep -qi 'permission denied'; then emit_err "permission"
    else emit_err "create_failed"; fi
    ;;

nginx-test)
    ssh_exec "${SUDO:+$SUDO }nginx -t 2>&1"
    out=$(printf '%s' "$SSH_OUT$SSH_ERR" | jq -Rsc '.')
    ok=false; printf '%s' "$SSH_OUT$SSH_ERR" | grep -qi 'syntax is ok' && ok=true
    printf '{"ok":true,"pass":%s,"output":%s}\n' "$ok" "$out"
    ;;

nginx-reload)
    ssh_exec "${SUDO:+$SUDO }nginx -s reload 2>&1 || ${SUDO:+$SUDO }systemctl reload nginx 2>&1"
    if [ "$SSH_RC" -eq 0 ]; then printf '{"ok":true}\n'
    else printf '{"ok":false,"reason":%s}\n' "$(printf '%s' "$SSH_ERR$SSH_OUT" | head -c 200 | jq -Rsc '.')"; fi
    ;;

# ---------------------------------------------------------------------------
# certbot: list certs + issue with the nginx plugin.
# ---------------------------------------------------------------------------
certbot-list)
    ssh_exec "${SUDO:+$SUDO }certbot certificates 2>/dev/null"
    if [ "$SSH_RC" -ne 0 ] && [ -z "$SSH_OUT" ]; then emit_err "no_certbot"; fi
    certs=$(printf '%s\n' "$SSH_OUT" | awk '
        /Certificate Name:/ {if(name){printf "%s\t%s\t%s\n",name,dom,ex}; name=$3; dom=""; ex=""}
        /Domains:/ {sub(/^[[:space:]]*Domains:[[:space:]]*/,""); dom=$0}
        /Expiry Date:/ {sub(/^[[:space:]]*Expiry Date:[[:space:]]*/,""); ex=$0}
        END {if(name){printf "%s\t%s\t%s\n",name,dom,ex}}' | jq -Rsc '
        split("\n") | map(select(length>0)) | map(split("\t")) |
        map({name:.[0], domains:(.[1]//""), expiry:(.[2]//"")})' 2>/dev/null)
    [ -n "$certs" ] || certs="[]"
    printf '{"ok":true,"certs":%s}\n' "$certs"
    ;;

certbot-issue)
    DOMAINS="${1:-}"; REDIRECT="${2:-1}"
    [ -n "$DOMAINS" ] || emit_err "no_domains"
    dargs=""
    IFS=',' read -ra dl <<< "$DOMAINS"
    for d in "${dl[@]}"; do
        case "$d" in *[!a-zA-Z0-9.-]*) continue;; esac
        [ -n "$d" ] && dargs+=" -d '$(rsq "$d")'"
    done
    [ -n "$dargs" ] || emit_err "no_domains"
    rflag="--redirect"; [ "$REDIRECT" = 0 ] && rflag="--no-redirect"
    ssh_exec "${SUDO:+$SUDO }certbot --nginx${dargs} --non-interactive --agree-tos --register-unsafely-without-email $rflag 2>&1"
    if [ "$SSH_RC" -eq 0 ]; then printf '{"ok":true,"output":%s}\n' "$(printf '%s' "$SSH_OUT" | tail -c 400 | jq -Rsc '.')"
    else printf '{"ok":false,"reason":%s}\n' "$(printf '%s' "$SSH_OUT$SSH_ERR" | tail -c 400 | jq -Rsc '.')"; fi
    ;;

# ---------------------------------------------------------------------------
# Transfers: scp up/down, reusing the warm master socket (so no re-auth). For a
# password server with no live master, the same SSH_ASKPASS helper feeds it.
# ---------------------------------------------------------------------------
scp-up|scp-down)
    SRC="${1:-}"; DST="${2:-}"; REC="${3:-0}"
    { [ -n "$SRC" ] && [ -n "$DST" ]; } || emit_err "no_path"
    SCPOPTS=(
        -o ConnectTimeout="${CNQ_SSH_TIMEOUT:-5}"
        -o ControlMaster=auto
        -o ControlPath="${RT}/cnq-ssh-%r@%h:%p"
        -o ControlPersist=60
        -o StrictHostKeyChecking=accept-new
        -o "Port=$PORT")
    recf=""; [ "$REC" = 1 ] && recf="-r"
    if [ "$SUB" = scp-up ]; then a_src="$SRC"; a_dst="${TARGET}:${DST}"
    else a_src="${TARGET}:${SRC}"; a_dst="$DST"; fi
    if [ "$AUTH" = password ]; then
        env "SSH_ASKPASS=$ASKPASS" SSH_ASKPASS_REQUIRE=force \
            scp $recf "${SCPOPTS[@]}" -- "$a_src" "$a_dst" 2>/dev/null
    elif [ -n "$KEY" ]; then
        scp -o BatchMode=yes $recf "${SCPOPTS[@]}" -o IdentitiesOnly=yes -i "$KEY" -- "$a_src" "$a_dst" 2>/dev/null
    else
        scp -o BatchMode=yes $recf "${SCPOPTS[@]}" -- "$a_src" "$a_dst" 2>/dev/null
    fi
    [ $? -eq 0 ] && printf '{"ok":true}\n' || emit_err "transfer_failed"
    ;;

*)
    emit_err "bad_subcommand"
    ;;
esac
