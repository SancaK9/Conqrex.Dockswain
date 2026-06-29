#!/usr/bin/env bash
#
# dockswain.sh: run docker commands on a remote host over SSH and print one
# normalized JSON line. Used by the Dockswain plasmoid.
#
# Auth is key-based and non-interactive (BatchMode=yes), so a command never hangs
# on a prompt: it fails fast and the reason is reported. A persistent SSH master
# (ControlPersist) is reused so repeated polls/actions return in milliseconds.
#
# Usage:
#   dockswain.sh hosts
#       Parse ~/.local/share/remmina/*.remmina SSH profiles -> {ok,hosts:[...]}.
#       The encrypted Remmina password *field* in the file is never read; for
#       password servers we instead reuse the password Remmina already saved in
#       the keyring (Secret Service, schema org.remmina.Password, looked up by
#       the profile's filename), so there is no copy-paste into the widget.
#
#   dockswain.sh <sub> <user@host> <port> <keyOrEmpty> [args...]
#       sub = probe | list | stats | compose | action | compose-action
#
# Env overrides (set by the widget): CNQ_DOCKER_CMD (default "docker"),
#   CNQ_SSH_TIMEOUT (default 5).
#
# Output is always a single JSON object; on failure: {"ok":false,"reason":"..."}.

set -u

SUB="${1:-}"; shift || true

REMMINA_DIR="${HOME}/.local/share/remmina"
# Runtime dir for the SSH control socket + transfer status/pid/log files. Prefer the
# session's 0700 /run/user/<uid>; if unset (cron/headless), fall back to a per-user
# 0700 dir under /tmp instead of bare world-traversable /tmp with predictable names.
RT="${XDG_RUNTIME_DIR:-}"
if [ -z "$RT" ]; then
    RT="/tmp/cnq-$(id -u)"
    # The name is predictable, so refuse a pre-existing symlink or a dir we don't own
    # (a local attacker could pre-create it to capture the control socket / status files).
    # (emit_err is defined below; this runs earlier, so inline the same JSON + exit.)
    if [ -L "$RT" ] || { [ -e "$RT" ] && [ ! -O "$RT" ]; }; then
        printf '{"ok":false,"reason":"unsafe_runtime_dir"}\n'; exit 0
    fi
    mkdir -p -m 700 "$RT" 2>/dev/null
    chmod 700 "$RT" 2>/dev/null      # tighten if it pre-existed (ours) with looser perms
fi
DOCKER="${CNQ_DOCKER_CMD:-docker}"
# Privileged filesystem reads/writes (container log files, /etc/nginx, certbot) run through
# sudo when EITHER the per-server "use sudo" toggle is on (CNQ_SUDO=1) or the docker command
# is driven via sudo. sudo -n never prompts, so a missing NOPASSWD rule fails fast instead of
# hanging (BatchMode philosophy). With neither, we run as the bare SSH user: works when that
# user is root, else reads come back unreadable and writes report a permission error.
case "$DOCKER" in "sudo "*|sudo) docker_sudo=1 ;; *) docker_sudo=0 ;; esac
if [ "${CNQ_SUDO:-0}" = "1" ] || [ "$docker_sudo" = "1" ]; then SUDO="sudo -n"; else SUDO=""; fi
NGINX_DIR="${CNQ_NGINX_DIR:-/etc/nginx}"

# Did a command fail because sudo wanted a password (no NOPASSWD, no TTY)? Used to turn a
# generic failure into an actionable reason in the nginx/certbot/file paths.
is_sudo_password_error() {
    [ -n "$SUDO" ] && printf '%s' "$1" | grep -qiE 'sudo:.*(password is required|terminal is required|no tty|askpass)|must have a tty to run sudo'
}

# escape a value so it can be embedded inside single quotes in a remote script: each
# ' becomes the POSIX sequence  '\''  (close-quote, escaped-quote, reopen-quote). The
# replacement is held in a var so no bare quote sits inside ${//} (which the parser
# would misread). printf keeps embedded newlines intact (unlike a line-based sed).
rsq() { local _q="'\\''"; printf '%s' "${1//\'/$_q}"; }

emit_err() { printf '{"ok":false,"reason":"%s"}\n' "$1"; exit 0; }

# JSON-encode an arbitrary string as a JSON string literal (safe for embedding)
jstr() { printf '%s' "${1-}" | jq -Rsc '.'; }

# a transfer id is used as part of a filename, so restrict it hard
valid_id() { [[ "$1" =~ ^[A-Za-z0-9_-]{1,64}$ ]]; }

# Never recursively delete a top-level system dir or the user's home. is_protected
# canonicalizes (resolves symlinks + '..') before matching, so /etc/../etc and a
# symlink-to-/etc are caught too. local-delete uses this directly; sftp-delete embeds
# an equivalent case in its REMOTE prologue (where $HOME is the remote user's home).
# Keep the two denylists in sync.
is_protected() {
    local p="$1" rt
    case "$p" in ""|.|..) return 0 ;; esac
    rt=$(readlink -f -- "$p" 2>/dev/null); [ -n "$rt" ] || rt="$p"
    rt="${rt%/}"; [ -n "$rt" ] || rt="/"          # /etc/ -> /etc so the denylist still matches
    case "$rt" in
        /|/bin|/boot|/dev|/etc|/home|/lib|/lib32|/lib64|/libx32|/proc|/root|/run|/sbin|/srv|/sys|/usr|/var)
            return 0 ;;
    esac
    [ "$rt" = "$HOME" ] && return 0
    return 1
}

# Is $1 a live cnq transfer worker (and not a stale pid the OS recycled for some other
# process)? Gates the group-kill in xfer-cancel and the keep decision in the sweep, so a
# leftover pid file can't make us signal a stranger or wedge a row. /proc confirms the
# identity; without /proc we fall back to liveness only.
worker_alive() {
    local p="${1:-}"
    [[ "$p" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$p" 2>/dev/null || return 1
    [ -r "/proc/$p/cmdline" ] || return 0
    grep -qa '__xfer-run' "/proc/$p/cmdline"
}

# Turn a NUL-separated `find ... -printf '%y\t%s\t%T@\t%m\t%f\0'` stream (on stdin)
# into the entries JSON array. NUL between records + TAB within keeps spaces and
# newlines in filenames intact; jq -Rs encodes everything safely. Entry shape lives
# in one place, shared by sftp-list and local-list.
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

# Find the .remmina SSH profile matching user@host:port (user optional). Echoes
# the profile path, or nothing. Lets us reuse Remmina's saved keyring password.
remmina_file_for() {
    local tgt="$1" prt="$2" u h f proto server ruser rhost rport
    u="${tgt%@*}"; [ "$u" = "$tgt" ] && u=""
    h="${tgt##*@}"
    [ -d "$REMMINA_DIR" ] || return 0
    for f in "$REMMINA_DIR"/*.remmina; do
        [ -e "$f" ] || continue
        proto=$(grep -aE '^protocol=' "$f" | head -1 | cut -d= -f2- | tr -d '\r')
        [ "$proto" = "SSH" ] || continue
        server=$(grep -aE '^server='   "$f" | head -1 | cut -d= -f2- | tr -d '\r')
        ruser=$(grep -aE '^username='  "$f" | head -1 | cut -d= -f2- | tr -d '\r')
        rhost="${server%%:*}"; rport=22
        case "$server" in *:*) rport="${server##*:}";; esac
        [[ "$rport" =~ ^[0-9]+$ ]] || rport=22
        if [ "$rhost" = "$h" ] && [ "$rport" = "$prt" ] \
           && { [ -z "$u" ] || [ "$ruser" = "$u" ]; }; then
            printf '%s' "$f"; return 0
        fi
    done
    return 0
}

# Echo the password Remmina saved in the keyring for a given profile path.
remmina_secret() {
    command -v secret-tool >/dev/null 2>&1 || return 0
    secret-tool lookup filename "$1" key password 2>/dev/null
}

# ---------------------------------------------------------------------------
# hosts: discover SSH targets from Remmina profiles
# ---------------------------------------------------------------------------
if [ "$SUB" = "hosts" ]; then
    declare -a arr=()
    if [ -d "$REMMINA_DIR" ]; then
        for f in "$REMMINA_DIR"/*.remmina; do
            [ -e "$f" ] || continue
            proto=$(grep -aE '^protocol='      "$f" | head -1 | cut -d= -f2- | tr -d '\r')
            [ "$proto" = "SSH" ] || continue
            name=$(grep -aE '^name='           "$f" | head -1 | cut -d= -f2- | tr -d '\r')
            group=$(grep -aE '^group='         "$f" | head -1 | cut -d= -f2- | tr -d '\r')
            server=$(grep -aE '^server='       "$f" | head -1 | cut -d= -f2- | tr -d '\r')
            user=$(grep -aE '^username='       "$f" | head -1 | cut -d= -f2- | tr -d '\r')
            key=$(grep -aE '^ssh_privatekey='  "$f" | head -1 | cut -d= -f2- | tr -d '\r')
            sshauth=$(grep -aE '^ssh_auth='    "$f" | head -1 | cut -d= -f2- | tr -d '\r')
            host="${server%%:*}"
            port=22
            case "$server" in *:*) port="${server##*:}";; esac
            [[ "$port" =~ ^[0-9]+$ ]] || port=22
            [ -n "$host" ] || continue
            # guess auth: stored key or an identity/agent/pubkey method -> key, else password
            if [ -n "$key" ]; then auth="key"
            elif [ "$sshauth" = "1" ] || [ "$sshauth" = "2" ] || [ "$sshauth" = "3" ] || [ "$sshauth" = "4" ]; then auth="key"
            else auth="password"; fi
            label="$name"; [ -n "$group" ] && label="$group / $name"
            # does Remmina already have a saved password for this profile?
            hassec=false
            if [ "$auth" = "password" ] && command -v secret-tool >/dev/null 2>&1 \
               && secret-tool lookup filename "$f" key password >/dev/null 2>&1; then
                hassec=true
            fi
            arr+=("$(jq -nc \
                --arg l "$label" --arg u "$user" --arg h "$host" \
                --argjson p "$port" --arg k "$key" --arg a "$auth" \
                --arg rf "$f" --argjson hs "$hassec" \
                '{label:$l,user:$u,host:$h,port:$p,key:$k,auth:$a,remmina:$rf,hasSecret:$hs}')")
        done
    fi
    if [ "${#arr[@]}" -gt 0 ]; then
        out=$(printf '%s\n' "${arr[@]}" | jq -sc '.')
    else
        out="[]"
    fi
    printf '{"ok":true,"hosts":%s}\n' "$out"
    exit 0
fi

# ---------------------------------------------------------------------------
# LOCAL file-manager ops + importers: run on THIS machine, no SSH target.
# Placed before the target guard so they never need a host. Args are $1.. (the
# subcommand was already shifted off).
# ---------------------------------------------------------------------------
if [ "$SUB" = "local-list" ]; then
    P="${1:-$HOME}"
    [ -d "$P" ] || emit_err "not_found"
    { [ -r "$P" ] && [ -x "$P" ]; } || emit_err "permission"
    arr=$(find -- "$P" -maxdepth 1 -mindepth 1 \
            -printf '%y\t%s\t%T@\t%m\t%f\0' 2>/dev/null | entries_from_find)
    [ -n "$arr" ] || arr="[]"
    printf '{"ok":true,"path":%s,"home":%s,"entries":%s}\n' \
        "$(jstr "$P")" "$(jstr "$HOME")" "$arr"
    exit 0
fi

if [ "$SUB" = "local-mkdir" ]; then
    P="${1:-}"; [ -n "$P" ] || emit_err "no_path"
    if mkdir -- "$P" 2>/dev/null; then printf '{"ok":true}\n'
    elif [ -e "$P" ]; then emit_err "exists"
    else emit_err "mkdir_failed"; fi
    exit 0
fi

if [ "$SUB" = "local-rename" ]; then
    O="${1:-}"; N="${2:-}"; { [ -n "$O" ] && [ -n "$N" ]; } || emit_err "no_path"
    if [ -e "$N" ]; then emit_err "exists"; fi
    if mv -n -- "$O" "$N" 2>/dev/null; then printf '{"ok":true}\n'; else emit_err "rename_failed"; fi
    exit 0
fi

if [ "$SUB" = "local-delete" ]; then
    P="${1:-}"; REC="${2:-0}"; [ -n "$P" ] || emit_err "no_path"
    is_protected "$P" && emit_err "refused"
    [[ "$REC" =~ ^[01]$ ]] || REC=0
    if [ "$REC" = 1 ]; then rm -r -- "$P" 2>/dev/null
    elif [ -d "$P" ] && [ ! -L "$P" ]; then rmdir -- "$P" 2>/dev/null
    else rm -- "$P" 2>/dev/null; fi
    if [ "$?" -eq 0 ]; then printf '{"ok":true}\n'; else emit_err "delete_failed"; fi
    exit 0
fi

# filezilla-hosts: parse ~/.config/filezilla/sitemanager.xml, SFTP entries only.
if [ "$SUB" = "filezilla-hosts" ]; then
    FZ="${HOME}/.config/filezilla/sitemanager.xml"
    [ -f "$FZ" ] || { printf '{"ok":true,"hosts":[],"sftp":0,"ftp":0}\n'; exit 0; }
    if command -v python3 >/dev/null 2>&1; then
        FZ="$FZ" python3 - <<'PY'
import os, json, base64, xml.etree.ElementTree as ET
fz = os.environ["FZ"]
try:
    root = ET.parse(fz).getroot()
except Exception:
    print(json.dumps({"ok": False, "reason": "parse_error"})); raise SystemExit
hosts = []; ftp = 0
def g(node, tag):
    e = node.find(tag); return (e.text or "").strip() if e is not None and e.text else ""
def walk(node, prefix):
    global ftp
    for child in list(node):
        if child.tag == "Folder":
            fname = "".join(t for t in [child.text or ""]).strip()
            walk(child, (prefix + " / " + fname).strip(" /") if fname else prefix)
        elif child.tag == "Server":
            proto = g(child, "Protocol")
            if proto != "1":                 # 1 = SFTP; everything else (0=FTP,...) skipped
                ftp += 1; continue
            host = g(child, "Host"); user = g(child, "User")
            name = g(child, "Name") or host
            keyf = g(child, "Keyfile")
            try: port = int(g(child, "Port") or "22")
            except Exception: port = 22
            auth = "key" if keyf else "password"
            has_secret = bool(g(child, "Pass")) and auth == "password"
            label = (prefix + " / " + name).strip(" /") if prefix else name
            hosts.append({"label": label, "user": user, "host": host, "port": port,
                          "key": keyf, "auth": auth, "filezilla": True, "hasSecret": has_secret})
servers = root.find("Servers")
walk(servers if servers is not None else root, "")
print(json.dumps({"ok": True, "hosts": hosts, "sftp": len(hosts), "ftp": ftp}))
PY
    else
        emit_err "no_parser"
    fi
    exit 0
fi

# filezilla-pass: print the decoded password for a given SFTP entry. The UI
# importer pipes it straight into `secret-tool store` (never on a cmdline).
if [ "$SUB" = "filezilla-pass" ]; then
    H="${1:-}"; PT="${2:-22}"; U="${3:-}"
    FZ="${HOME}/.config/filezilla/sitemanager.xml"
    [ -f "$FZ" ] || exit 0
    command -v python3 >/dev/null 2>&1 || exit 0
    FZ="$FZ" FZH="$H" FZP="$PT" FZU="$U" python3 - <<'PY'
import os, base64, xml.etree.ElementTree as ET
fz=os.environ["FZ"]; H=os.environ["FZH"]; P=os.environ["FZP"]; U=os.environ["FZU"]
def g(n,t):
    e=n.find(t); return (e.text or "").strip() if e is not None and e.text else ""
try: root=ET.parse(fz).getroot()
except Exception: raise SystemExit
for s in root.iter("Server"):
    if g(s,"Protocol")!="1": continue
    if g(s,"Host")==H and (g(s,"Port") or "22")==P and g(s,"User")==U:
        pw=s.find("Pass")
        if pw is not None and pw.text:
            enc=(pw.attrib.get("encoding") or "").lower()
            try:
                import sys
                sys.stdout.write(base64.b64decode(pw.text).decode("utf-8","replace") if enc=="base64" else pw.text)
            except Exception: pass
        break
PY
    exit 0
fi

# ---------------------------------------------------------------------------
# everything else needs an ssh target
# ---------------------------------------------------------------------------
TARGET="${1:-}"; PORT="${2:-22}"; KEY="${3:-}"
shift 3 2>/dev/null || true
[ -n "$TARGET" ] || emit_err "no_target"
[[ "$PORT" =~ ^[0-9]+$ ]] || PORT=22

AUTH="${CNQ_AUTH:-key}"
SECRET_KEY="${TARGET}:${PORT}"

COMMON_OPTS=(
    -o ConnectTimeout="${CNQ_SSH_TIMEOUT:-5}"
    -o ControlMaster=auto
    -o ControlPath="${RT}/cnq-ssh-%r@%h:%p"
    -o ControlPersist=60
    -o ServerAliveInterval=15
    -o ServerAliveCountMax=3
    -o StrictHostKeyChecking=accept-new
    -p "$PORT")

if [ "$AUTH" = "password" ]; then
    # password fetched from the secret store (never on a command line).
    # 1) an explicit widget-stored password wins (set via "Set password");
    # 2) otherwise reuse the password Remmina already saved for this host, so a
    #    Remmina-imported server works without re-entering anything.
    PW=$(secret-tool lookup service cnq-dockswain host "$SECRET_KEY" 2>/dev/null)
    if [ -z "$PW" ]; then
        RF=$(remmina_file_for "$TARGET" "$PORT")
        [ -n "$RF" ] && PW=$(remmina_secret "$RF")
    fi
    [ -n "$PW" ] || emit_err "no_password"
    export SSHPASS="$PW"
    SSH=(sshpass -e ssh
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

list)
    ssh_exec "$DOCKER ps -a --no-trunc --format '{{json .}}'"
    if [ "$SSH_RC" -ne 0 ]; then
        reason=$(classify)
        reachable=true
        case "$reason" in ssh_auth|dns|refused|timeout|unreachable|ssh_error) reachable=false;; esac
        printf '{"ok":false,"reachable":%s,"reason":"%s"}\n' "$reachable" "$reason"
        exit 0
    fi
    containers=$(printf '%s\n' "$SSH_OUT" | jq -sc '
        [ .[] | {
            id:      (.ID // "" | .[0:12]),
            fullId:  (.ID // ""),
            name:    (.Names // ""),
            image:   (.Image // ""),
            state:   (.State // ""),
            status:  (.Status // ""),
            health:  (.HealthStatus // ""),
            ports:   (.Ports // ""),
            networks:(.Networks // ""),
            created: (.CreatedAt // "")
        } ]' 2>/dev/null)
    [ -n "$containers" ] || containers="[]"
    printf '{"ok":true,"reachable":true,"containers":%s}\n' "$containers"
    ;;

stats)
    ssh_exec "$DOCKER stats --no-stream --format '{{json .}}'"
    if [ "$SSH_RC" -ne 0 ]; then emit_err "$(classify)"; fi
    stats=$(printf '%s\n' "$SSH_OUT" | jq -sc '
        reduce .[] as $s ({};
            .[($s.ID // "" | .[0:12])] = {
                cpu:$s.CPUPerc, mem:$s.MemPerc, memUsage:$s.MemUsage,
                net:$s.NetIO, block:$s.BlockIO, pids:$s.PIDs
            })' 2>/dev/null)
    [ -n "$stats" ] || stats="{}"
    printf '{"ok":true,"stats":%s}\n' "$stats"
    ;;

compose)
    ssh_exec "$DOCKER compose ls -a --format json"
    if [ "$SSH_RC" -ne 0 ]; then emit_err "$(classify)"; fi
    projects=$(printf '%s' "$SSH_OUT" | jq -c '
        if type=="array" then
            [ .[] | { name:.Name, status:.Status,
                      configFiles: ((.ConfigFiles // "") | split(",")) } ]
        else [] end' 2>/dev/null)
    [ -n "$projects" ] || projects="[]"
    # best-effort docker swarm stacks (empty unless the remote is a swarm manager)
    stacks="[]"
    ssh_exec "$DOCKER stack ls --format '{{json .}}' 2>/dev/null"
    if [ "$SSH_RC" -eq 0 ] && [ -n "$SSH_OUT" ]; then
        s=$(printf '%s\n' "$SSH_OUT" | jq -sc '
            [ .[] | { name:.Name, services:(.Services // "") } ]' 2>/dev/null)
        [ -n "$s" ] && stacks="$s"
    fi
    printf '{"ok":true,"projects":%s,"stacks":%s}\n' "$projects" "$stacks"
    ;;

# stack-action: swarm stack ops. Only `rm` (take a whole stack down) is supported;
# `up`/redeploy needs the original compose file, which we do not have.
stack-action)
    ACT="${1:-}"; NAME="${2:-}"
    [ "$ACT" = "rm" ] || emit_err "bad_action"
    [ -n "$NAME" ] || emit_err "no_name"
    nesc=$(rsq "$NAME")
    ssh_exec "$DOCKER stack rm '$nesc'"
    if [ "$SSH_RC" -eq 0 ]; then
        printf '{"ok":true}\n'
    else
        msg=$(printf '%s' "$SSH_ERR" | tr -d '\r\n"' | head -c 160)
        printf '{"ok":false,"reason":"%s"}\n' "${msg:-stack_failed}"
    fi
    ;;

# disk: server filesystem usage of the docker data root + `docker system df`.
disk)
    remote='root=$('"$DOCKER"' info --format "{{.DockerRootDir}}" 2>/dev/null); [ -n "$root" ] || root=/var/lib/docker; df -PB1 "$root" 2>/dev/null | awk '\''NR==2{print $2" "$3" "$4" "$5}'\''; echo "@@DF@@"; '"$DOCKER"' system df --format "{{json .}}" 2>/dev/null'
    ssh_exec "$remote"
    if [ "$SSH_RC" -ne 0 ] && [ -z "$SSH_OUT" ]; then emit_err "$(classify)"; fi
    # first line (before the marker) = "size used avail use%" in bytes; rest is system df NDJSON
    read -r dsize dused davail dusep <<< "$(printf '%s\n' "$SSH_OUT" | awk '/^@@DF@@/{exit} {print}')"
    sysdf=$(printf '%s\n' "$SSH_OUT" | awk 'f{print} /^@@DF@@/{f=1}' | jq -sc '
        [ .[] | {type:.Type, count:(.TotalCount), active:.Active, size:.Size, reclaimable:.Reclaimable} ]' 2>/dev/null)
    [ -n "$sysdf" ] || sysdf="[]"
    disk=$(jq -nc --arg s "${dsize:-}" --arg u "${dused:-}" --arg a "${davail:-}" --arg p "${dusep:-}" \
        '{size:($s|tonumber? // 0), used:($u|tonumber? // 0), avail:($a|tonumber? // 0), usePct:$p}')
    printf '{"ok":true,"disk":%s,"df":%s}\n' "$disk" "$sysdf"
    ;;

# prune: SAFE SET ONLY. Never volumes, never `-a`: those can drop tagged images
# or delete volume data (e.g. databases). Each is confirmed in the UI first.
prune)
    WHAT="${1:-}"
    case "$WHAT" in
        builder)    ssh_exec "$DOCKER builder prune -f" ;;          # build cache
        images)     ssh_exec "$DOCKER image prune -f" ;;            # dangling images only
        containers) ssh_exec "$DOCKER container prune -f" ;;        # stopped containers
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

# container-logs: size of every container's json log file, mapped back to its name —
# the `du .../containers/*/*-json.log` the user runs by hand, but readable from the
# widget so a runaway log (e.g. a 30 GB one) is easy to spot and truncate. The path
# comes from `docker inspect .LogPath` (handles a custom data root / non-default
# driver). Reading those root-owned files needs privilege, so we reuse $SUDO. Per
# container, size is: a byte count, -1 if it exists but we can't stat it (no root/
# sudo), or -2 if there is no json-file log at all (a different logging driver).
container-logs)
    remote=$(cat <<REMOTE
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
)
    ssh_exec "$remote"
    if [ "$SSH_RC" -ne 0 ] && [ -z "$SSH_OUT" ]; then emit_err "$(classify)"; fi
    # fields are space-separated and never contain spaces (hex id, docker name, int,
    # /var/lib/docker/.../-json.log). Sort readable sizes desc, then unreadable, then
    # no-log; total counts only readable bytes.
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

# truncate-log: empty one container's json log file (truncate -s 0). The path is taken
# from `docker inspect` (never built from the id) and must end in -json.log, so this can
# only ever zero a docker json-file log — not an arbitrary file. id is validated as hex.
truncate-log)
    ID="${1:-}"
    [ -n "$ID" ] || emit_err "no_id"
    [[ "$ID" =~ ^[0-9a-fA-F]{12,64}$ ]] || emit_err "bad_id"
    IDe=$(rsq "$ID")
    remote=$(cat <<REMOTE
lp=\$($DOCKER inspect --format '{{.LogPath}}' '$IDe' 2>/dev/null)
[ -n "\$lp" ] || { echo NOLOG; exit 0; }
case "\$lp" in *-json.log) ;; *) echo BADPATH; exit 0 ;; esac
if $SUDO truncate -s 0 "\$lp" 2>/dev/null; then echo OK; else echo FAIL; fi
REMOTE
)
    ssh_exec "$remote"
    if [ "$SSH_RC" -ne 0 ] && [ -z "$SSH_OUT" ]; then emit_err "$(classify)"; fi
    case "$(printf '%s' "$SSH_OUT" | tr -d '\r\n ')" in
        OK)      printf '{"ok":true}\n' ;;
        NOLOG)   emit_err "no_log" ;;
        BADPATH) emit_err "bad_path" ;;
        *)       emit_err "truncate_failed" ;;
    esac
    ;;

action)
    ACT="${1:-}"; ID="${2:-}"
    [ -n "$ID" ] || emit_err "no_id"
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
        esc=$(rsq "$f")              # single-quote-escape for the remote shell
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
    [[ "$TAIL" =~ ^[0-9]+$ ]] || TAIL=200
    ssh_exec "$DOCKER logs --tail $TAIL $ID 2>&1"
    if [ "$SSH_RC" -ne 0 ] && [ -z "$SSH_OUT" ]; then emit_err "$(classify)"; fi
    text=$(printf '%s' "$SSH_OUT" | sed $'s/\x1b\\[[0-9;]*[mK]//g' | jq -Rsc '.')
    [ -n "$text" ] || text='""'
    printf '{"ok":true,"text":%s}\n' "$text"
    ;;

edit)
    # Edit a remote file reusing the warm/authenticated SSH connection (no KIO,
    # no extra password). Detach a session that pulls the file to a temp copy,
    # opens it in the editor, and writes it back over SSH on save (1s poll) and on
    # close. Returns immediately.
    P="${1:-}"; [ -n "$P" ] || emit_err "no_path"
    setsid bash "$0" __edit-run "$TARGET" "$PORT" "$KEY" "$P" </dev/null >/dev/null 2>&1 &
    printf '{"ok":true}\n'
    exit 0
    ;;

__edit-run)
    P="${1:-}"; [ -n "$P" ] || exit 0
    tmp=$(mktemp -d 2>/dev/null) || exit 0
    f="$tmp/$(basename "$P")"
    pesc=$(rsq "$P")
    # Read/write-back honor the per-server sudo toggle so root-owned configs (e.g. under
    # /etc/nginx) round-trip. Writes go through `tee` because a `> file` redirect is the
    # local shell's, not sudo's, and so could not create/overwrite a root-owned file.
    "${SSH[@]}" "${SUDO:+$SUDO }cat -- '$pesc'" > "$f" 2>/dev/null || { rm -rf "$tmp"; exit 0; }
    sig=$(cksum < "$f" 2>/dev/null)   # content signature (mtime is too coarse)
    # background watcher: push the temp back whenever its content changes (on save)
    (
        while sleep 1; do
            [ -f "$f" ] || break
            cur=$(cksum < "$f" 2>/dev/null)
            if [ "$cur" != "$sig" ]; then
                sig="$cur"
                "${SSH[@]}" "${SUDO:+$SUDO }tee -- '$pesc' >/dev/null" < "$f" 2>/dev/null
            fi
        done
    ) &
    watcher=$!
    case "${CNQ_EDITOR:-kate}" in
        *kate)   kate --new --block "$f" >/dev/null 2>&1 ;;
        *kwrite) kwrite "$f" >/dev/null 2>&1 ;;
        *)       "${CNQ_EDITOR:-kate}" "$f" >/dev/null 2>&1 ;;
    esac
    kill "$watcher" 2>/dev/null
    # final flush if content changed since the last push
    cur=$(cksum < "$f" 2>/dev/null)
    [ "$cur" != "$sig" ] && "${SSH[@]}" "${SUDO:+$SUDO }tee -- '$pesc' >/dev/null" < "$f" 2>/dev/null
    rm -rf "$tmp"
    exit 0
    ;;

readfile)
    P="${1:-}"; [ -n "$P" ] || emit_err "no_path"
    pesc=$(rsq "$P")
    ssh_exec "${SUDO:+$SUDO }cat -- '$pesc'"
    if [ "$SSH_RC" -ne 0 ]; then
        if   is_sudo_password_error "$SSH_ERR";              then emit_err "sudo_password"
        elif echo "$SSH_ERR" | grep -qi 'no such file';   then emit_err "not_found"
        elif echo "$SSH_ERR" | grep -qi 'permission denied'; then emit_err "permission"
        else emit_err "$(classify)"; fi
    fi
    text=$(printf '%s' "$SSH_OUT" | jq -Rsc '.')
    [ -n "$text" ] || text='""'
    printf '{"ok":true,"path":%s,"text":%s}\n' \
        "$(printf '%s' "$P" | jq -Rsc '.')" "$text"
    ;;

# ---------------------------------------------------------------------------
# SFTP file-manager: remote directory listing + file ops over the warm master
# ---------------------------------------------------------------------------
sftp-list)
    P="${1:-}"; [ -n "$P" ] || emit_err "no_path"
    pesc=$(rsq "$P")
    # NUL-separated find output must go through a FILE, not a bash var: $(...) drops
    # NULs, and PIPESTATUS inside $() is invisible outside. Raw bytes -> file -> jq;
    # rc is then the real ssh exit code.
    outf=$(mktemp 2>/dev/null) || emit_err "tmp_failed"
    errf=$(mktemp 2>/dev/null) || { rm -f "$outf"; emit_err "tmp_failed"; }
    "${SSH[@]}" \
        "find -- '$pesc' -maxdepth 1 -mindepth 1 -printf '%y\t%s\t%T@\t%m\t%f\0'" \
        >"$outf" 2>"$errf"
    rc=$?
    SSH_ERR=$(cat "$errf" 2>/dev/null)
    entries=$(entries_from_find < "$outf")
    rm -f "$outf" "$errf"
    if [ "$rc" -ne 0 ] && { [ -z "$entries" ] || [ "$entries" = "[]" ]; }; then
        if   echo "$SSH_ERR" | grep -qi 'no such file';      then emit_err "not_found"
        elif echo "$SSH_ERR" | grep -qi 'permission denied'; then emit_err "permission"
        else emit_err "$(classify)"; fi
    fi
    [ -n "$entries" ] || entries="[]"
    printf '{"ok":true,"path":%s,"entries":%s}\n' "$(jstr "$P")" "$entries"
    ;;

sftp-home)
    ssh_exec 'printf %s "$HOME"'
    if [ "$SSH_RC" -ne 0 ] && [ -z "$SSH_OUT" ]; then emit_err "$(classify)"; fi
    h=$(printf '%s' "$SSH_OUT" | tr -d '\r\n')
    [ -n "$h" ] || h="/"
    printf '{"ok":true,"home":%s}\n' "$(jstr "$h")"
    ;;

sftp-mkdir)
    P="${1:-}"; [ -n "$P" ] || emit_err "no_path"
    pesc=$(rsq "$P")
    ssh_exec "mkdir -- '$pesc' 2>&1"
    if [ "$SSH_RC" -eq 0 ]; then printf '{"ok":true}\n'
    elif echo "$SSH_OUT$SSH_ERR" | grep -qi 'file exists';      then emit_err "exists"
    elif echo "$SSH_OUT$SSH_ERR" | grep -qi 'permission denied'; then emit_err "permission"
    else emit_err "mkdir_failed"; fi
    ;;

sftp-rename)
    O="${1:-}"; N="${2:-}"
    { [ -n "$O" ] && [ -n "$N" ]; } || emit_err "no_path"
    oesc=$(rsq "$O"); nesc=$(rsq "$N")
    ssh_exec "mv -n -- '$oesc' '$nesc' 2>&1"
    if [ "$SSH_RC" -eq 0 ]; then printf '{"ok":true}\n'
    elif echo "$SSH_OUT$SSH_ERR" | grep -qi 'permission denied'; then emit_err "permission"
    elif echo "$SSH_OUT$SSH_ERR" | grep -qi 'no such file';      then emit_err "not_found"
    else emit_err "rename_failed"; fi
    ;;

sftp-delete)
    P="${1:-}"; REC="${2:-0}"
    [ -n "$P" ] || emit_err "no_path"
    case "$P" in /|""|.|..) emit_err "refused";; esac
    [[ "$REC" =~ ^[01]$ ]] || REC=0
    pesc=$(rsq "$P")
    # Authoritative protected-path guard runs on the REMOTE, where $HOME is the SSH
    # user's home (frequently root's). The path is passed as a positional arg ($1) so
    # there is no second layer of quoting; rec is $2. Canonicalize (resolve symlinks +
    # '..') then denylist. A refusal prints "cnq-refused" and exits 9. POSIX sh only.
    # Keep this denylist in sync with is_protected().
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
    # the guard exits 9 on refusal (distinct from rm's 1). classify on the exit code,
    # not a substring match, so a path that merely contains "cnq-refused" isn't misread.
    if [ "$SSH_RC" -eq 9 ];                                       then emit_err "refused"
    elif [ "$SSH_RC" -eq 0 ]; then printf '{"ok":true}\n'
    elif echo "$SSH_OUT$SSH_ERR" | grep -qi 'not empty';        then emit_err "not_empty"
    elif echo "$SSH_OUT$SSH_ERR" | grep -qi 'permission denied'; then emit_err "permission"
    elif echo "$SSH_OUT$SSH_ERR" | grep -qi 'no such file';     then emit_err "not_found"
    else emit_err "delete_failed"; fi
    ;;

# ---------------------------------------------------------------------------
# Transfer engine: detached worker writes NDJSON progress to a status file the
# UI polls via xfer-status (same setsid+poll pattern as edit -> __edit-run).
# ---------------------------------------------------------------------------
xfer)
    ID="${1:-}"; DIR="${2:-}"; SRC="${3:-}"; DST="${4:-}"; REC="${5:-0}"; SM="${6:-}"
    valid_id "$ID" || emit_err "bad_id"
    case "$DIR" in up|down) ;; *) emit_err "bad_direction";; esac
    { [ -n "$SRC" ] && [ -n "$DST" ]; } || emit_err "no_path"
    [[ "$REC" =~ ^[01]$ ]] || REC=0
    # Reap orphaned status/pid/log/cancel files from transfers whose worker died
    # without the UI calling xfer-clear (plasmashell crash, panel removed).
    # A transfer with a LIVE worker is kept regardless of age, so a long-running (>6h)
    # transfer stays cancellable; only a dead-and-stale (>6h) set is removed.
    for _s in "$RT"/cnq-xfer-*.status; do
        [ -e "$_s" ] || continue                 # no matches -> literal glob, skip
        _b="${_s%.status}"; _p="${_b}.pid"; _w=""
        [ -f "$_p" ] && _w=$(cat "$_p" 2>/dev/null)
        worker_alive "$_w" && continue           # a live worker of ours: keep, any age
        [ -n "$(find "$_s" -mmin +360 2>/dev/null)" ] && \
            rm -f "${_b}".status "${_b}".status.log "${_b}".pid "${_b}".cancel 2>/dev/null
    done
    sf="${RT}/cnq-xfer-${ID}.status"
    rm -f "${RT}/cnq-xfer-${ID}.cancel" 2>/dev/null   # clear any stale cancel sentinel
    : > "$sf" 2>/dev/null || emit_err "no_statusfile"
    setsid bash "$0" __xfer-run "$TARGET" "$PORT" "$KEY" \
        "$ID" "$DIR" "$SRC" "$DST" "$REC" "$SM" </dev/null >/dev/null 2>&1 &
    printf '{"ok":true,"id":%s}\n' "$(jstr "$ID")"
    exit 0
    ;;

__xfer-run)
    ID="${1:-}"; DIR="${2:-}"; SRC="${3:-}"; DST="${4:-}"; REC="${5:-0}"; SM="${6:-}"
    valid_id "$ID" || exit 0
    sf="${RT}/cnq-xfer-${ID}.status"
    pf="${RT}/cnq-xfer-${ID}.pid"
    cf="${RT}/cnq-xfer-${ID}.cancel"
    emitline() { printf '%s\n' "$1" >> "$sf" 2>/dev/null; }
    # A delivered SIGTERM (xfer-cancel kills the worker's process group) ends the
    # transfer as *cancelled*, not a generic error. The sentinel file covers the
    # startup window before $pf existed for xfer-cancel to find; honor it now, and
    # again right before the transfer launches.
    finish_cancelled() { emitline '{"event":"error","code":"cancelled"}'; rm -f "$pf" 2>/dev/null; exit 0; }
    # Arm the trap BEFORE publishing the pid: once xfer-cancel can find $pf and signal
    # us, the handler is already in place, so no kill-by-default-disposition gap.
    trap finish_cancelled TERM
    printf '%s\n' "$$" > "$pf" 2>/dev/null
    [ -e "$cf" ] && finish_cancelled

    # transfer ssh options reusing the SAME warm master socket (Port via -o so one
    # option set works for ssh, scp and rsync's -e transport).
    TOPTS=(
        -o ConnectTimeout="${CNQ_SSH_TIMEOUT:-5}"
        -o ControlMaster=auto
        -o ControlPath="${RT}/cnq-ssh-%r@%h:%p"
        -o ControlPersist=60
        -o StrictHostKeyChecking=accept-new
        -o "Port=$PORT")
    KEYOPT=""; KEYARR=()
    if [ "$AUTH" != "password" ] && [ -n "$KEY" ]; then
        KEYOPT="-o IdentitiesOnly=yes -i $(rsq "$KEY")"   # for rsync's -e string
        KEYARR=(-o IdentitiesOnly=yes -i "$KEY")          # for scp (array: spaces safe)
    fi

    # pick the tool: rsync needs to be on BOTH ends, else scp.
    tool="${CNQ_SFTP_TOOL:-auto}"
    use=scp
    if [ "$tool" = rsync ] || [ "$tool" = auto ]; then
        if command -v rsync >/dev/null 2>&1; then
            ssh_exec "command -v rsync >/dev/null 2>&1 && echo Y"
            [ "$SSH_OUT" = Y ] && use=rsync
        fi
        [ "$tool" = rsync ] && use=rsync     # forced even if probe failed (will error visibly)
    fi
    [ "$tool" = scp ] && use=scp

    [ -e "$cf" ] && finish_cancelled   # cancel arrived during the rsync-probe round trip
    rec_flag=""; [ "$REC" = 1 ] && rec_flag="-r"
    emitline "$(jq -nc --arg t "$use" '{event:"start",tool:$t}')"
    rc=1

    if [ "$use" = rsync ]; then
        rflag="-a"; [ "$REC" = 1 ] || rflag="-a --no-r"
        # whitelisted sync mode -> rsync flag (don't interpolate raw user text)
        case "$SM" in
            newer)    rflag="$rflag --update" ;;
            new-only) rflag="$rflag --ignore-existing" ;;
            size)     rflag="$rflag --size-only" ;;
            existing) rflag="$rflag --existing" ;;
        esac
        if [ "$AUTH" = password ]; then sshcmd="sshpass -e ssh ${TOPTS[*]} ${KEYOPT}"
        else sshcmd="ssh -o BatchMode=yes ${TOPTS[*]} ${KEYOPT}"; fi
        if [ "$DIR" = up ]; then a_src="$SRC"; a_dst="${TARGET}:${DST}"
        else a_src="${TARGET}:${SRC}"; a_dst="$DST"; fi
        # -s (--protect-args): remote side does not re-split spaces/globs.
        # LC_ALL=C so --info=progress2 uses dot-decimal numbers the regex parses.
        LC_ALL=C rsync $rflag -s --info=progress2 -e "$sshcmd" -- "$a_src" "$a_dst" 2>&1 \
          | tr '\r' '\n' \
          | while IFS= read -r ln; do
                case "$ln" in
                  *%*)
                    pct=$(printf '%s' "$ln" | grep -oE '[0-9]+%' | tail -1 | tr -d '%')
                    byt=$(printf '%s' "$ln" | grep -oE '^[ ]*[0-9,]+' | head -1 | tr -d ', ')
                    rate=$(printf '%s' "$ln" | grep -oE '[0-9.]+[kKMG]?B/s' | tail -1)
                    [ -n "$pct" ] && emitline "$(jq -nc \
                        --argjson p "${pct:-0}" --arg b "${byt:-0}" --arg r "${rate:-}" \
                        '{event:"progress",pct:$p,bytes:($b|tonumber? //0),rate:$r}')"
                    ;;
                esac
            done
        rc=${PIPESTATUS[0]}
    else
        # scp fallback: no parseable progress non-interactively, so indeterminate then done/fail.
        # Modern scp (OpenSSH 9+) uses the SFTP protocol with NO remote shell, so the
        # remote path is taken literally; pass it bare (the whole arg is one shell word).
        emitline '{"event":"progress","pct":-1}'
        if [ "$DIR" = up ]; then a_src="$SRC"; a_dst="${TARGET}:${DST}"
        else a_src="${TARGET}:${SRC}"; a_dst="$DST"; fi
        if [ "$AUTH" = password ]; then
            sshpass -e scp $rec_flag "${TOPTS[@]}" -- "$a_src" "$a_dst" >>"${sf}.log" 2>&1
        else
            scp -o BatchMode=yes $rec_flag "${TOPTS[@]}" "${KEYARR[@]}" -- "$a_src" "$a_dst" >>"${sf}.log" 2>&1
        fi
        rc=$?
    fi

    # The transfer has a definite result. IGNORE a late cancel (don't take the default
    # TERM disposition) so its group-kill can't kill us before we record the result or
    # leak the pid file. Write the real terminal, then drop the pid.
    trap '' TERM
    if [ "$rc" -eq 0 ]; then emitline '{"event":"done","pct":100}'
    else emitline "$(jq -nc --argjson c "$rc" '{event:"error",code:$c}')"; fi
    rm -f "$pf" 2>/dev/null
    exit 0
    ;;

xfer-status)
    ID="${1:-}"; valid_id "$ID" || emit_err "bad_id"
    sf="${RT}/cnq-xfer-${ID}.status"
    [ -f "$sf" ] || emit_err "no_xfer"
    last=$(grep -E '"event":"(progress|start)"' "$sf" 2>/dev/null | tail -1)
    term=$(grep -E '"event":"(done|error)"'      "$sf" 2>/dev/null | tail -1)
    [ -n "$last" ] || last='{}'
    if [ -n "$term" ]; then
        printf '{"ok":true,"id":%s,"done":true,"last":%s,"terminal":%s}\n' \
            "$(jstr "$ID")" "$last" "$term"
    else
        printf '{"ok":true,"id":%s,"done":false,"last":%s}\n' "$(jstr "$ID")" "$last"
    fi
    ;;

xfer-cancel)
    ID="${1:-}"; valid_id "$ID" || emit_err "bad_id"
    pf="${RT}/cnq-xfer-${ID}.pid"; sf="${RT}/cnq-xfer-${ID}.status"; cf="${RT}/cnq-xfer-${ID}.cancel"
    : > "$cf" 2>/dev/null       # sentinel FIRST: covers the worker's startup window (no pid yet)
    wp=""; [ -f "$pf" ] && wp=$(cat "$pf" 2>/dev/null)
    # SIGTERM the worker's group only if it is genuinely our live worker (worker_alive
    # checks identity via /proc), so a stale pid the OS recycled isn't signalled.
    worker_alive "$wp" && kill -TERM -- "-$wp" 2>/dev/null
    # Always make sure the UI gets a terminal, unless the worker already wrote one. This
    # is relabel-safe: during its commit the worker IGNORES our TERM (trap '' TERM) and
    # writes its real done/error, and the grep guard skips the append once one exists.
    # So a finished transfer is never relabeled, while a dead/stale worker (which would
    # otherwise leave the row stuck "in progress") still gets a cancelled terminal.
    grep -qE '"event":"(done|error)"' "$sf" 2>/dev/null \
        || printf '{"event":"error","code":"cancelled"}\n' >> "$sf" 2>/dev/null
    rm -f "$pf" 2>/dev/null      # clear a stale pid file (a live worker removes its own)
    printf '{"ok":true}\n'
    ;;

xfer-clear)
    ID="${1:-}"; valid_id "$ID" || emit_err "bad_id"
    rm -f "${RT}/cnq-xfer-${ID}.status" "${RT}/cnq-xfer-${ID}.pid" \
          "${RT}/cnq-xfer-${ID}.status.log" "${RT}/cnq-xfer-${ID}.cancel" 2>/dev/null
    printf '{"ok":true}\n'
    ;;

nginx-info)
    B=$(rsq "$NGINX_DIR"); SU="${SUDO:+$SUDO }"
    remote=$(cat <<REMOTE
base='$B'
conf="\$base/nginx.conf"
style=confd
if ${SU}test -f "\$conf" && ${SU}grep -qE 'sites-enabled' "\$conf" 2>/dev/null; then style=sites
elif ${SU}test -d "\$base/sites-available"; then style=sites; fi
printf 'style=%s\n' "\$style"
printf 'conf=%s\n' "\$(${SU}test -f "\$conf" && echo 1 || echo 0)"
# meta <file> -> "<ssl 0|1>\t<server_name domains>"
# Collects every server_name token across the file (comments stripped), drops the
# catch-all '_' and duplicates, so a redirect/catch-all block written first does
# not mask the real vhost's domains.
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
    printf 'site\t%s\t%s\t' "\$n" "\$en"; meta "\$f"; printf '\n'
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
    printf 'site\t%s\t%s\t' "\$n" "\$en"; meta "\$f"; printf '\n'
  done
fi
REMOTE
)
    ssh_exec "$remote"
    if [ "$SSH_RC" -ne 0 ] && [ -z "$SSH_OUT" ]; then
        is_sudo_password_error "$SSH_ERR" && emit_err "sudo_password"
        emit_err "$(classify)"
    fi
    style=$(printf '%s\n' "$SSH_OUT" | sed -n 's/^style=//p' | head -1)
    hasconf=$(printf '%s\n' "$SSH_OUT" | sed -n 's/^conf=//p' | head -1)
    [ "$hasconf" = "1" ] && hasconf_json=true || hasconf_json=false
    sites=$(printf '%s\n' "$SSH_OUT" | awk -F'\t' '$1=="site"{printf "%s\t%s\t%s\t%s\n",$2,$3,$4,$5}' \
        | jq -R -s -c 'split("\n")|map(select(length>0))|map(split("\t"))|map({name:.[0],enabled:(.[1]=="1"),ssl:(.[2]=="1"),domains:(.[3]//"")})' 2>/dev/null)
    [ -n "$sites" ] || sites="[]"
    printf '{"ok":true,"base":%s,"style":"%s","hasConf":%s,"sites":%s}\n' \
        "$(printf '%s' "$NGINX_DIR" | jq -Rsc '.')" "${style:-confd}" "$hasconf_json" "$sites"
    ;;

nginx-test)
    ssh_exec "${SUDO:+$SUDO }nginx -t 2>&1"
    out=$(printf '%s' "$SSH_OUT" | jq -Rsc '.'); [ -n "$out" ] || out='""'
    if [ "$SSH_RC" -eq 0 ]; then printf '{"ok":true,"output":%s}\n' "$out"
    else printf '{"ok":false,"output":%s}\n' "$out"; fi
    ;;

nginx-reload)
    ssh_exec "${SUDO:+$SUDO }systemctl reload nginx 2>&1 || ${SUDO:+$SUDO }nginx -s reload 2>&1"
    out=$(printf '%s' "$SSH_OUT" | jq -Rsc '.'); [ -n "$out" ] || out='""'
    if [ "$SSH_RC" -eq 0 ]; then printf '{"ok":true,"output":%s}\n' "$out"
    else printf '{"ok":false,"output":%s}\n' "$out"; fi
    ;;

nginx-site)
    ACT="${1:-}"; NAME="${2:-}"
    case "$ACT" in enable|disable) ;; *) emit_err "bad_action";; esac
    [ -n "$NAME" ] || emit_err "no_name"
    B=$(rsq "$NGINX_DIR"); N=$(rsq "$NAME"); SU="${SUDO:+$SUDO }"
    remote=$(cat <<REMOTE
base='$B'; name='$N'; act='$ACT'
name=\$(basename "\$name")
conf="\$base/nginx.conf"
style=confd
if ${SU}test -f "\$conf" && ${SU}grep -qE 'sites-enabled' "\$conf" 2>/dev/null; then style=sites
elif ${SU}test -d "\$base/sites-available"; then style=sites; fi
if [ "\$style" = sites ]; then
  if [ "\$act" = enable ]; then ${SU}ln -sf "../sites-available/\$name" "\$base/sites-enabled/\$name"
  else ${SU}rm -f "\$base/sites-enabled/\$name"; fi
else
  # never overwrite the opposite-state twin (would silently destroy a config)
  if [ "\$act" = enable ]; then
    ${SU}test -e "\$base/conf.d/\$name" && { printf 'CONFLICT\n'; exit 0; }
    ${SU}test -f "\$base/conf.d/\$name.disabled" && ${SU}mv "\$base/conf.d/\$name.disabled" "\$base/conf.d/\$name"
  else
    ${SU}test -e "\$base/conf.d/\$name.disabled" && { printf 'CONFLICT\n'; exit 0; }
    ${SU}test -f "\$base/conf.d/\$name" && ${SU}mv "\$base/conf.d/\$name" "\$base/conf.d/\$name.disabled"
  fi
fi
REMOTE
)
    ssh_exec "$remote"
    printf '%s' "$SSH_OUT" | grep -q '^CONFLICT$' && emit_err "twin_exists"
    if [ "$SSH_RC" -eq 0 ]; then printf '{"ok":true}\n'
    elif is_sudo_password_error "$SSH_ERR"; then emit_err "sudo_password"
    else msg=$(printf '%s' "$SSH_ERR" | tr -d '\r\n"' | head -c 160); printf '{"ok":false,"reason":"%s"}\n' "${msg:-failed}"; fi
    ;;

# nginx-create NAME "domain[ domain...]" proxy|static TARGET ENABLE(0|1) MKROOT(0|1)
# Writes a new server{} block. proxy -> reverse-proxy to TARGET (a URL); static ->
# serves files from TARGET (a root dir). certbot adds the 443/SSL block later.
nginx-create)
    NAME="${1:-}"; SNAMES="${2:-}"; TYPE="${3:-proxy}"; TARGET="${4:-}"; EN="${5:-1}"; MK="${6:-0}"
    [ -n "$NAME" ]   || emit_err "no_name"
    [ -n "$SNAMES" ] || emit_err "no_domain"
    case "$TYPE" in proxy|static) ;; *) emit_err "bad_type";; esac
    [ -n "$TARGET" ] || emit_err "no_target"
    [[ "$EN" =~ ^[01]$ ]] || EN=1
    [[ "$MK" =~ ^[01]$ ]] || MK=0
    B=$(rsq "$NGINX_DIR"); N=$(rsq "$NAME"); SN=$(rsq "$SNAMES")
    TY=$(rsq "$TYPE"); TG=$(rsq "$TARGET"); SU="${SUDO:+$SUDO }"
    remote=$(cat <<REMOTE
base='$B'; name='$N'; snames='$SN'; type='$TY'; target='$TG'; enable='$EN'; mkroot='$MK'
name=\$(basename "\$name")
[ -n "\$name" ] || { printf 'ERR\tbad_name\n'; exit 0; }
conf="\$base/nginx.conf"
style=confd
if ${SU}test -f "\$conf" && ${SU}grep -qE 'sites-enabled' "\$conf" 2>/dev/null; then style=sites
elif ${SU}test -d "\$base/sites-available"; then style=sites; fi
if [ "\$style" = sites ]; then
  ${SU}mkdir -p "\$base/sites-available" "\$base/sites-enabled" 2>/dev/null
  file="\$base/sites-available/\$name"
else
  cdir="\$base/conf.d"; ${SU}mkdir -p "\$cdir" 2>/dev/null
  case "\$name" in *.conf) ;; *) name="\$name.conf";; esac
  # reject if EITHER the enabled or disabled twin already exists
  { ${SU}test -e "\$cdir/\$name" || ${SU}test -e "\$cdir/\$name.disabled"; } && { printf 'ERR\texists\n'; exit 0; }
  if [ "\$enable" = 1 ]; then file="\$cdir/\$name"; else file="\$cdir/\$name.disabled"; fi
fi
${SU}test -e "\$file" && { printf 'ERR\texists\n'; exit 0; }
{
  printf 'server {\n'
  printf '    listen 80;\n'
  printf '    listen [::]:80;\n'
  printf '    server_name %s;\n\n' "\$snames"
  if [ "\$type" = proxy ]; then
    printf '    location / {\n'
    printf '        proxy_pass %s;\n' "\$target"
    cat <<'NGINX'
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
NGINX
  else
    printf '    root %s;\n' "\$target"
    cat <<'NGINX'
    index index.html index.htm;

    location / {
        try_files \$uri \$uri/ =404;
    }
NGINX
  fi
  printf '}\n'
} | ${SU}tee "\$file" >/dev/null 2>&1 || { printf 'ERR\twrite_failed\n'; exit 0; }
if [ "\$style" = sites ] && [ "\$enable" = 1 ]; then
  ${SU}ln -sf "../sites-available/\$name" "\$base/sites-enabled/\$name" 2>/dev/null
fi
if [ "\$type" = static ] && [ "\$mkroot" = 1 ] && [ -n "\$target" ] && ${SU}test ! -d "\$target"; then
  ${SU}mkdir -p "\$target" 2>/dev/null && \
    printf '<!doctype html>\n<title>%s</title>\n<h1>It works: %s</h1>\n' "\$snames" "\$snames" | ${SU}tee "\$target/index.html" >/dev/null 2>&1
fi
printf 'OK\t%s\n' "\$file"
REMOTE
)
    ssh_exec "$remote"
    is_sudo_password_error "$SSH_ERR" && emit_err "sudo_password"
    if [ "$SSH_RC" -ne 0 ] && [ -z "$SSH_OUT" ]; then emit_err "$(classify)"; fi
    line=$(printf '%s\n' "$SSH_OUT" | grep -E '^(OK|ERR)\b' | tail -1)
    status=$(printf '%s' "$line" | cut -f1)
    rest=$(printf '%s' "$line" | cut -f2-)
    if [ "$status" = "OK" ]; then
        printf '{"ok":true,"path":%s}\n' "$(printf '%s' "$rest" | jq -Rsc '.')"
    else
        printf '{"ok":false,"reason":"%s"}\n' "${rest:-create_failed}"
    fi
    ;;

# nginx-certbot "domain[ domain...]" REDIRECT(0|1)
# Obtain/install a Let's Encrypt cert via the nginx plugin. No email
# (--register-unsafely-without-email). certbot reloads nginx itself on success.
nginx-certbot)
    DOMAINS="${1:-}"; REDIR="${2:-1}"
    [ -n "$DOMAINS" ] || emit_err "no_domain"
    [[ "$REDIR" =~ ^[01]$ ]] || REDIR=1
    D=$(rsq "$DOMAINS"); SU="${SUDO:+$SUDO }"
    remote=$(cat <<REMOTE
command -v certbot >/dev/null 2>&1 || { printf 'NOCERTBOT\n'; exit 0; }
domains='$D'; redir='$REDIR'
set --
set -f                                  # no globbing: keep domains literal
for d in \$domains; do set -- "\$@" -d "\$d"; done
set +f
[ "\$#" -gt 0 ] || { printf 'NODOMAIN\n'; exit 0; }
if [ "\$redir" = 1 ]; then rflag=--redirect; else rflag=--no-redirect; fi
${SU}certbot --nginx -n --agree-tos --register-unsafely-without-email "\$rflag" "\$@" 2>&1
printf '\n@@RC@@%s\n' "\$?"      # leading \n so the marker is always on its own line
REMOTE
)
    ssh_exec "$remote"
    if [ "$SSH_RC" -ne 0 ] && [ -z "$SSH_OUT" ]; then emit_err "$(classify)"; fi
    printf '%s' "$SSH_OUT" | grep -q '^NOCERTBOT$' && emit_err "no_certbot"
    is_sudo_password_error "$SSH_OUT$SSH_ERR" && emit_err "sudo_password"
    rc=$(printf '%s\n' "$SSH_OUT" | sed -n 's/^@@RC@@//p' | tail -1)
    body=$(printf '%s\n' "$SSH_OUT" | grep -vE '^@@RC@@')
    out=$(printf '%s' "$body" | jq -Rsc '.'); [ -n "$out" ] || out='""'
    if [ "${rc:-1}" = 0 ]; then printf '{"ok":true,"output":%s}\n' "$out"
    else printf '{"ok":false,"output":%s}\n' "$out"; fi
    ;;

# nginx-certs: list installed Let's Encrypt certs and their expiry (certbot certificates)
nginx-certs)
    ssh_exec "command -v certbot >/dev/null 2>&1 || { echo @@NOCERTBOT@@; exit 0; }; ${SUDO:+$SUDO }certbot certificates 2>/dev/null"
    if [ "$SSH_RC" -ne 0 ] && [ -z "$SSH_OUT" ]; then emit_err "$(classify)"; fi
    if printf '%s' "$SSH_OUT" | grep -q '@@NOCERTBOT@@'; then
        printf '{"ok":true,"certbot":false,"certs":[]}\n'; exit 0
    fi
    certs=$(printf '%s\n' "$SSH_OUT" | awk '
        function emit() { if (have) printf "%s\t%s\t%s\t%s\n", name, dom, edate, valid }
        /Certificate Name:/ { emit(); name=$0;
            sub(/^[[:space:]]*Certificate Name:[[:space:]]*/,"",name);
            dom=""; edate=""; valid=""; have=1; next }
        /Domains:/ { d=$0; sub(/^[[:space:]]*Domains:[[:space:]]*/,"",d); dom=d; next }
        /Expiry Date:/ { e=$0; sub(/^[[:space:]]*Expiry Date:[[:space:]]*/,"",e);
            edate=e; sub(/[[:space:]]*\(.*/,"",edate);
            valid=""; if (index(e,"(")>0){ valid=e; sub(/.*\(/,"",valid); sub(/\).*/,"",valid) } next }
        END { emit() }' \
        | jq -R -s -c 'split("\n")|map(select(length>0))|map(split("\t"))
                       |map({name:.[0],domains:(.[1]//""),expiry:(.[2]//""),valid:(.[3]//"")})' 2>/dev/null)
    [ -n "$certs" ] || certs="[]"
    printf '{"ok":true,"certbot":true,"certs":%s}\n' "$certs"
    ;;

# ---------------------------------------------------------------------------
# conf.d snippets: the shared include files (upstreams, maps, ...) under
# $NGINX_DIR/conf.d that are not server blocks. Listed, created, edited (readfile /
# edit), enabled/disabled (a .disabled twin) and deleted here. Everything is confined
# to conf.d and a name may only be a single path component.
# ---------------------------------------------------------------------------
nginx-confd)
    SU="${SUDO:+$SUDO }"; B=$(rsq "$NGINX_DIR")
    # Enumerate via ${SU}find (not a shell glob) so a root-only conf.d is still readable
    # under sudo, and skip a .disabled file when its enabled twin exists (one row per snippet).
    remote=$(cat <<REMOTE
base='$B'; cd="\$base/conf.d"
${SU}test -d "\$cd" || { echo "@@NODIR@@"; exit 0; }
${SU}find "\$cd" -maxdepth 1 -type f 2>/dev/null | while IFS= read -r f; do
  b=\$(basename "\$f")
  case "\$b" in
    *.disabled) n="\${b%.disabled}"; ${SU}test -e "\$cd/\$n" && continue; en=0 ;;
    *)          n="\$b"; en=1 ;;
  esac
  sz=\$(${SU}stat -c %s "\$f" 2>/dev/null || echo 0)
  printf 'file\t%s\t%s\t%s\t%s\n' "\$n" "\$f" "\$en" "\$sz"
done
REMOTE
)
    ssh_exec "$remote"
    # A sudo password prompt makes the remote `test -d` fail and emit @@NODIR@@ spuriously,
    # so detect that before trusting the marker (and before classify, which needs no stdout).
    is_sudo_password_error "$SSH_ERR" && emit_err "sudo_password"
    if [ "$SSH_RC" -ne 0 ] && [ -z "$SSH_OUT" ]; then emit_err "$(classify)"; fi
    cdir="$NGINX_DIR/conf.d"
    if printf '%s' "$SSH_OUT" | grep -q '@@NODIR@@'; then
        printf '{"ok":true,"dir":%s,"files":[]}\n' "$(jstr "$cdir")"; exit 0
    fi
    files=$(printf '%s\n' "$SSH_OUT" | awk -F'\t' '$1=="file"{printf "%s\t%s\t%s\t%s\n",$2,$3,$4,$5}' \
        | jq -Rsc 'split("\n")|map(select(length>0))|map(split("\t"))|
            map({name:.[0], path:.[1], enabled:(.[2]=="1"), size:(.[3]|tonumber? // 0)})' 2>/dev/null)
    [ -n "$files" ] || files="[]"
    printf '{"ok":true,"dir":%s,"files":%s}\n' "$(jstr "$cdir")" "$files"
    ;;

# nginx-confd-toggle ACT NAME — flip conf.d/NAME <-> conf.d/NAME.disabled. Always acts
# in conf.d (a snippet lives there regardless of the vhost layout); never clobbers the twin.
nginx-confd-toggle)
    ACT="${1:-}"; NAME="${2:-}"
    case "$ACT" in enable|disable) ;; *) emit_err "bad_action";; esac
    [ -n "$NAME" ] || emit_err "no_name"
    case "$NAME" in ''|*/*|..|.) emit_err "bad_name";; esac
    SU="${SUDO:+$SUDO }"; B=$(rsq "$NGINX_DIR"); N=$(rsq "$NAME")
    remote=$(cat <<REMOTE
base='$B'; cd="\$base/conf.d"; name='$N'; act='$ACT'
name=\$(basename "\$name")
if [ "\$act" = enable ]; then
  ${SU}test -e "\$cd/\$name" && { printf 'CONFLICT\n'; exit 0; }
  ${SU}test -f "\$cd/\$name.disabled" && ${SU}mv "\$cd/\$name.disabled" "\$cd/\$name"
else
  ${SU}test -e "\$cd/\$name.disabled" && { printf 'CONFLICT\n'; exit 0; }
  ${SU}test -f "\$cd/\$name" && ${SU}mv "\$cd/\$name" "\$cd/\$name.disabled"
fi
printf 'OK\n'
REMOTE
)
    ssh_exec "$remote"
    printf '%s' "$SSH_OUT" | grep -q '^CONFLICT$' && emit_err "twin_exists"
    if printf '%s' "$SSH_OUT" | grep -q '^OK$'; then printf '{"ok":true}\n'
    elif is_sudo_password_error "$SSH_ERR"; then emit_err "sudo_password"
    elif echo "$SSH_ERR" | grep -qi 'permission denied'; then emit_err "permission"
    else emit_err "toggle_failed"; fi
    ;;

# nginx-confd-del NAME — remove conf.d/NAME and its .disabled twin. Confined to conf.d.
nginx-confd-del)
    NAME="${1:-}"
    [ -n "$NAME" ] || emit_err "no_name"
    case "$NAME" in ''|*/*|..|.) emit_err "bad_name";; esac
    SU="${SUDO:+$SUDO }"; B=$(rsq "$NGINX_DIR"); N=$(rsq "$NAME")
    remote=$(cat <<REMOTE
base='$B'; cd="\$base/conf.d"; name='$N'
name=\$(basename "\$name")
${SU}rm -f -- "\$cd/\$name" "\$cd/\$name.disabled" && printf 'OK\n'
REMOTE
)
    ssh_exec "$remote"
    if printf '%s' "$SSH_OUT" | grep -q '^OK$'; then printf '{"ok":true}\n'
    elif is_sudo_password_error "$SSH_ERR"; then emit_err "sudo_password"
    elif echo "$SSH_ERR" | grep -qi 'permission denied'; then emit_err "permission"
    else emit_err "delete_failed"; fi
    ;;

# nginx-confd-new NAME — create a new (templated) conf.d/NAME; ".conf" added if no
# extension. Refuses if either twin already exists. Returns the path so the UI can edit it.
nginx-confd-new)
    NAME="${1:-}"
    [ -n "$NAME" ] || emit_err "no_name"
    case "$NAME" in *[!A-Za-z0-9._-]*|''|..|.) emit_err "bad_name";; esac
    SU="${SUDO:+$SUDO }"; B=$(rsq "$NGINX_DIR"); N=$(rsq "$NAME")
    remote=$(cat <<REMOTE
base='$B'; cd="\$base/conf.d"; name='$N'
name=\$(basename "\$name")
case "\$name" in *.*) ;; *) name="\$name.conf";; esac
${SU}test -e "\$cd/\$name" && { printf 'EXISTS\n'; exit 0; }
${SU}test -e "\$cd/\$name.disabled" && { printf 'EXISTS\n'; exit 0; }
${SU}mkdir -p "\$cd" 2>/dev/null
printf '# %s\n# nginx include — e.g. an upstream {} or map {} block.\n\n' "\$name" \
  | ${SU}tee "\$cd/\$name" >/dev/null 2>&1 && printf 'OK\t%s\n' "\$cd/\$name"
REMOTE
)
    ssh_exec "$remote"
    printf '%s' "$SSH_OUT" | grep -q '^EXISTS$' && emit_err "exists"
    is_sudo_password_error "$SSH_ERR" && emit_err "sudo_password"
    line=$(printf '%s\n' "$SSH_OUT" | grep -E '^OK\b' | tail -1)
    if [ -n "$line" ]; then
        printf '{"ok":true,"path":%s}\n' "$(printf '%s' "$line" | cut -f2- | jq -Rsc '.')"
    elif echo "$SSH_ERR" | grep -qi 'permission denied'; then emit_err "permission"
    else emit_err "create_failed"; fi
    ;;

*)
    emit_err "unknown_subcommand"
    ;;
esac
