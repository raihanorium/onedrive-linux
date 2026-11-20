#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# onedrive-linux setup
#
# Mounts Microsoft OneDrive on Linux with rclone + FUSE3 and (optionally) a
# systemd user service.  Phases:
#   1. Pre-flight checks            (read only)
#   2. Collect configuration        (prompts; defaults come from setup.conf)
#   3. Save configuration           (setup.conf, only keys that changed)
#   4. Install rclone / fuse3       (only if missing)
#   5. Create mount + cache folders
#   6. Configure the rclone remote  (rclone authorize + rclone config create;
#                                    the user's OWN OneDrive is picked
#                                    automatically via Microsoft Graph)
#   7. Create systemd user service  (only if autostart = yes)
#
# Usage: ./setup.sh [-y|--defaults] [-c|--config FILE]
#
# Secrets (token, client id/secret) are NEVER written to setup.conf. They are
# asked for at runtime (hidden input) or taken from the environment variables
# ONEDRIVE_TOKEN / ONEDRIVE_CLIENT_ID / ONEDRIVE_CLIENT_SECRET, kept in memory
# only, and handed straight to "rclone config create".
# -----------------------------------------------------------------------------
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONF_FILE="$SCRIPT_DIR/setup.conf"
USE_DEFAULTS=0
STTY_SAVED=""
CURRENT_STEP="initialisation"
WRITES_STARTED=0

# Keys that are prompted for (in order) and therefore may be written back.
PROMPT_KEYS=(REMOTE_NAME MOUNT_DIR CACHE_DIR SERVICE_NAME AUTOSTART)

# -----------------------------------------------------------------------------
# Output helpers
# -----------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_R=$'\e[31m' C_G=$'\e[32m' C_Y=$'\e[33m' C_B=$'\e[1;34m' C_D=$'\e[2m' C_0=$'\e[0m'
else
    C_R='' C_G='' C_Y='' C_B='' C_D='' C_0=''
fi
info() { printf '  %s\n' "$*"; }
ok()   { printf '  %s✔%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
step() { CURRENT_STEP="$*"; printf '\n%s==> %s%s\n' "$C_B" "$*" "$C_0"; }

die() {
    if [[ -n $STTY_SAVED ]]; then stty "$STTY_SAVED" 2>/dev/null || true; STTY_SAVED=""; fi
    printf '\n  %s✘ %s%s\n' "$C_R" "$*" "$C_0" >&2
    if (( WRITES_STARTED )); then
        printf '  %sSetup stopped during: %s. It is safe to fix the problem and re-run ./setup.sh.%s\n' \
            "$C_D" "$CURRENT_STEP" "$C_0" >&2
    else
        printf '  %sNothing was changed on this system.%s\n' "$C_D" "$C_0" >&2
    fi
    exit 1
}

on_error() {
    local rc=$1 line=$2 cmd=$3
    trap - ERR
    die "Unexpected error (exit code $rc) at setup.sh line $line: $cmd"
}
trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR
trap 'printf "\n"; die "Interrupted by user."' INT TERM

usage() {
    cat <<EOF
Usage: $0 [options]

  -y, --defaults          Don't prompt; use the values from the config file.
  -c, --config FILE       Use FILE instead of $SCRIPT_DIR/setup.conf
  -h, --help              Show this help.

Optional environment variables (never saved to the config file):
  ONEDRIVE_TOKEN          rclone OneDrive token JSON (skips browser login)
  ONEDRIVE_CLIENT_ID      OAuth client ID of your own Azure app
  ONEDRIVE_CLIENT_SECRET  OAuth client secret of your own Azure app
EOF
}

# -----------------------------------------------------------------------------
# Config file handling
# -----------------------------------------------------------------------------
expand_path() {
    local p=$1
    case $p in
        "~")    p=$HOME ;;
        "~/"*)  p="$HOME/${p#"~/"}" ;;
    esac
    [[ $p == /* ]] || p="$PWD/$p"
    # strip trailing slashes (but keep "/")
    while [[ $p == */ && $p != / ]]; do p=${p%/}; done
    printf '%s' "$p"
}

load_conf() {
    [[ -f $CONF_FILE ]] || die "Config file not found: $CONF_FILE"
    [[ -r $CONF_FILE ]] || die "Config file is not readable: $CONF_FILE"
    bash -n "$CONF_FILE" 2>/dev/null || die "Config file has a syntax error: $CONF_FILE (check quotes)"
    # shellcheck source=setup.conf
    source "$CONF_FILE" || die "Could not load config file: $CONF_FILE"

    : "${REMOTE_NAME:=onedrive}"
    : "${SERVICE_NAME:=rclone-onedrive}"
    : "${MOUNT_DIR:=~/OneDrive}"
    : "${CACHE_DIR:=~/.cache/rclone-onedrive}"
    : "${AUTOSTART:=yes}"
    : "${DRIVE_ID:=}"

    # Secrets must not live in the config file — ignore them if present.
    local k
    for k in TOKEN CLIENT_ID CLIENT_SECRET; do
        if [[ -n ${!k:-} ]]; then
            warn "$k found in $CONF_FILE — ignored. Secrets are never read from or saved to the config file; please remove that line."
        fi
    done
    TOKEN=${ONEDRIVE_TOKEN:-}
    CLIENT_ID=${ONEDRIVE_CLIENT_ID:-}
    CLIENT_SECRET=${ONEDRIVE_CLIENT_SECRET:-}
    : "${VFS_CACHE_MODE:=full}" "${VFS_CACHE_MAX_SIZE:=10G}" "${VFS_CACHE_MAX_AGE:=24h}"
    : "${DIR_CACHE_TIME:=5m}" "${EXTRA_MOUNT_ARGS:=}" "${RCLONE_INSTALL_METHOD:=auto}"
}

# conf_set KEY VALUE — replace (or append) KEY='VALUE' in the config file,
# keeping comments, ordering and file permissions.
conf_set() {
    local key=$1 val=$2 line tmp
    line="${key}='${val//\'/\'\\\'\'}'"
    tmp=$(mktemp "${CONF_FILE}.XXXXXX") || die "Cannot create temp file next to $CONF_FILE"
    if grep -q "^${key}=" "$CONF_FILE"; then
        KEY=$key LINE=$line awk '
            BEGIN { k = ENVIRON["KEY"] "="; l = ENVIRON["LINE"] }
            index($0, k) == 1 {
                c = ""
                q = sprintf("%c", 39)   # single quote
                if (match($0, q "[[:space:]]+#[^" q "]*$")) c = substr($0, RSTART + 1)   # keep inline comment
                print l c; next
            }
            { print }' "$CONF_FILE" >"$tmp" || { rm -f "$tmp"; die "Failed to update $key in $CONF_FILE"; }
    else
        { cat "$CONF_FILE"; printf '%s\n' "$line"; } >"$tmp" || { rm -f "$tmp"; die "Failed to add $key to $CONF_FILE"; }
    fi
    cat "$tmp" >"$CONF_FILE" || { rm -f "$tmp"; die "Cannot write $CONF_FILE"; }
    rm -f "$tmp"
}

# -----------------------------------------------------------------------------
# Prompt helpers
# -----------------------------------------------------------------------------
# ask VAR "Label" validator — Enter keeps the current value.
ask() {
    local var=$1 label=$2 validator=$3 ans err
    while :; do
        if (( USE_DEFAULTS )); then
            printf '  %-28s %s\n' "$label:" "${!var}"
        else
            read -r -p "  $label [${!var}]: " ans \
                || die "No input available (stdin closed). Use --defaults for unattended runs."
            [[ -n $ans ]] && printf -v "$var" '%s' "$ans"
        fi
        if err=$("$validator" "${!var}"); then
            return 0
        fi
        warn "$err"
        (( USE_DEFAULTS )) && die "Invalid value for $var in $CONF_FILE"
    done
}

valid_any() { [[ -n $1 ]] || { echo "Value cannot be empty."; return 1; }; }
valid_remote() {
    [[ $1 =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]] \
        || { echo "Use letters, digits, '_', '-', '.' only."; return 1; }
}
valid_service() {
    [[ $1 =~ ^[A-Za-z0-9_][A-Za-z0-9_.@-]*$ && $1 != *.service ]] \
        || { echo "Use letters, digits, '_', '-', '.', '@' only (without .service)."; return 1; }
}
valid_yesno() {
    case ${1,,} in y|yes|n|no) return 0 ;; esac
    echo "Answer yes or no."; return 1
}
norm_yesno() { case ${1,,} in y|yes) echo yes ;; *) echo no ;; esac; }

# read_secret VAR "Label" — hidden input, kept in memory only.
# The terminal is switched to non-canonical mode so long pastes (OneDrive
# tokens are >4096 chars) are not truncated by the tty line limit.
read_secret() {
    local var=$1 label=$2 ans="" hint="empty"
    [[ -n ${!var} ]] && hint="set from environment"
    printf '  %s [%s]: ' "$label" "$hint" >&2
    if [[ -t 0 ]]; then
        STTY_SAVED=$(stty -g)
        stty -echo -icanon min 1 time 0
        IFS= read -r ans || die "No input available."
        stty "$STTY_SAVED"; STTY_SAVED=""
        printf '%s\n' "$( [[ -n $ans ]] && echo '(received)' )" >&2
    else
        IFS= read -r ans || die "No input available (stdin closed)."
        printf '\n' >&2
    fi
    [[ -n $ans ]] && printf -v "$var" '%s' "$ans"
    return 0
}

# yesno "Question" default(yes|no) -> returns 0 for yes
yesno() {
    local q=$1 def=$2 ans hint
    [[ $def == yes ]] && hint="Y/n" || hint="y/N"
    if (( USE_DEFAULTS )); then
        printf '  %s [%s]: %s\n' "$q" "$hint" "$def"
        [[ $def == yes ]]; return
    fi
    while :; do
        read -r -p "  $q [$hint]: " ans || die "No input available (stdin closed)."
        ans=${ans:-$def}
        case ${ans,,} in y|yes) return 0 ;; n|no) return 1 ;; esac
        warn "Answer yes or no."
    done
}

# -----------------------------------------------------------------------------
# Phase 1: pre-flight
# -----------------------------------------------------------------------------
PKG_MGR=""
NEED_RCLONE=0
NEED_FUSE=0
NEED_CURL=0
SYSTEMD_USER_OK=0

detect_pkg_mgr() {
    local m
    for m in apt-get dnf yum pacman zypper; do
        if command -v "$m" >/dev/null 2>&1; then PKG_MGR=$m; return 0; fi
    done
    return 1
}

preflight() {
    step "Pre-flight checks"
    [[ $(uname -s) == Linux ]] || die "This setup only supports Linux."
    (( EUID != 0 )) || die "Do not run this as root/sudo. Run it as the user who will use OneDrive; it will ask for sudo when needed."
    ok "Running as user '$USER' on Linux"

    command -v rclone >/dev/null 2>&1 && ok "rclone found: $(rclone version 2>/dev/null | head -n1)" \
        || { NEED_RCLONE=1; info "rclone not installed — will be installed"; }
    command -v fusermount3 >/dev/null 2>&1 && ok "fuse3 found: $(fusermount3 -V 2>&1 | head -n1)" \
        || { NEED_FUSE=1; info "fuse3 not installed — will be installed"; }
    command -v curl >/dev/null 2>&1 && ok "curl found" \
        || { NEED_CURL=1; info "curl not installed — will be installed (needed to find your drive)"; }

    if (( NEED_RCLONE || NEED_FUSE || NEED_CURL )); then
        command -v sudo >/dev/null 2>&1 || die "'sudo' is required to install missing packages."
        if (( NEED_FUSE || NEED_CURL )) || [[ $RCLONE_INSTALL_METHOD != script ]]; then
            detect_pkg_mgr || die "No supported package manager (apt, dnf, yum, pacman, zypper). Install rclone and fuse3 manually, then re-run."
            ok "Package manager: $PKG_MGR"
        fi
    fi

    if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
        SYSTEMD_USER_OK=1; ok "systemd user session available"
    else
        warn "systemd user session not reachable — autostart service cannot be created in this session."
    fi
    command -v mountpoint >/dev/null 2>&1 || die "'mountpoint' (util-linux) is required."
}

# -----------------------------------------------------------------------------
# Phase 2: collect configuration
# -----------------------------------------------------------------------------
declare -A ORIG
RECONFIGURE_REMOTE=no
REMOTE_EXISTS=no
MOUNT_PATH="" CACHE_PATH=""

validate_paths() {
    MOUNT_PATH=$(expand_path "$MOUNT_DIR")
    CACHE_PATH=$(expand_path "$CACHE_DIR")
    [[ $MOUNT_PATH != "$CACHE_PATH" ]] || { echo "Mount and cache folders must be different."; return 1; }
    [[ $CACHE_PATH/ != "$MOUNT_PATH"/* ]] || { echo "Cache folder must not be inside the mount folder."; return 1; }
    [[ $MOUNT_PATH != "$HOME" && $MOUNT_PATH != / ]] || { echo "Refusing to mount over $MOUNT_PATH."; return 1; }
    if [[ -e $MOUNT_PATH && ! -d $MOUNT_PATH ]]; then echo "Mount path exists and is not a folder: $MOUNT_PATH"; return 1; fi
    if [[ -e $CACHE_PATH && ! -d $CACHE_PATH ]]; then echo "Cache path exists and is not a folder: $CACHE_PATH"; return 1; fi
    if mountpoint -q "$MOUNT_PATH" 2>/dev/null; then
        # Allowed only if it's our own service holding the mount (it will be restarted).
        if ! { (( SYSTEMD_USER_OK )) && systemctl --user is-active --quiet "$SERVICE_NAME.service"; }; then
            echo "$MOUNT_PATH is already a mount point (not by service '$SERVICE_NAME'). Unmount it or pick another folder."
            return 1
        fi
    elif [[ -d $MOUNT_PATH ]] && [[ -n $(ls -A "$MOUNT_PATH" 2>/dev/null) ]]; then
        echo "Mount folder $MOUNT_PATH is not empty. Choose an empty/new folder."
        return 1
    fi
}

collect() {
    step "Configuration  ${C_D}(press Enter to keep the value in brackets)${C_0}"
    local k
    for k in "${PROMPT_KEYS[@]}"; do ORIG[$k]=${!k}; done

    ask REMOTE_NAME  "rclone remote name"     valid_remote
    while :; do
        ask MOUNT_DIR    "Mount folder"           valid_any
        ask CACHE_DIR    "Cache folder"           valid_any
        ask SERVICE_NAME "systemd service name"   valid_service
        local err
        if err=$(validate_paths); then validate_paths; break; fi
        warn "$err"
        (( USE_DEFAULTS )) && die "Fix MOUNT_DIR / CACHE_DIR in $CONF_FILE"
    done
    ask AUTOSTART "Start automatically at login? (yes/no)" valid_yesno
    AUTOSTART=$(norm_yesno "$AUTOSTART")
    if [[ $AUTOSTART == yes ]] && (( ! SYSTEMD_USER_OK )); then
        die "Autostart requested but the systemd user session is not reachable. Log in to a desktop/ssh session with systemd, or answer 'no'."
    fi

    if command -v rclone >/dev/null 2>&1 && rclone listremotes 2>/dev/null | grep -Fxq "${REMOTE_NAME}:"; then
        REMOTE_EXISTS=yes
        info "An rclone remote named '$REMOTE_NAME' already exists."
        if yesno "Re-create it (re-authenticate)?" no; then
            RECONFIGURE_REMOTE=yes
        else
            check_existing_drive
        fi
    fi

    if [[ $REMOTE_EXISTS == no || $RECONFIGURE_REMOTE == yes ]]; then collect_auth; fi

    local auth drive
    [[ -n $TOKEN ]] && auth="provided token" || auth="browser login with your Microsoft account"
    [[ -n $CLIENT_ID ]] && auth+=", own client ID"
    [[ -n $DRIVE_ID ]] && drive="DRIVE_ID from setup.conf" || drive="your own OneDrive (auto-detected)"
    if [[ $REMOTE_EXISTS == yes && $RECONFIGURE_REMOTE == no ]]; then
        auth="unchanged"
        [[ $FIX_DRIVE == yes ]] && drive="switch to '$FIX_NAME'" || drive="unchanged"
    fi

    printf '\n  %sSummary%s\n' "$C_B" "$C_0"
    printf '    %-22s %s\n' \
        "rclone remote"  "$REMOTE_NAME$( [[ $REMOTE_EXISTS == yes ]] && { [[ $RECONFIGURE_REMOTE == yes ]] && echo ' (re-create)' || echo ' (keep existing)'; } )" \
        "Mount folder"   "$MOUNT_PATH" \
        "Cache folder"   "$CACHE_PATH" \
        "Service"        "$SERVICE_NAME.service" \
        "Autostart"      "$AUTOSTART" \
        "Authentication" "$auth" \
        "Drive"          "$drive"
    echo
    yesno "Proceed?" yes || { info "Aborted. Nothing was changed."; exit 0; }
}

# Ask for credentials. They are NOT saved to setup.conf — they go straight to
# "rclone config create" (which stores them in your own rclone.conf).
collect_auth() {
    printf '\n  %sAuthentication%s  %s(never saved to setup.conf; Enter = skip)%s\n' "$C_B" "$C_0" "$C_D" "$C_0"
    if (( USE_DEFAULTS )); then
        info "Using ONEDRIVE_TOKEN / ONEDRIVE_CLIENT_ID / ONEDRIVE_CLIENT_SECRET from the environment, if set."
    else
        read_secret CLIENT_ID "OAuth client ID (empty = rclone's built-in app)"
        if [[ -n $CLIENT_ID ]]; then
            read_secret CLIENT_SECRET "OAuth client secret"
        fi
        while :; do
            read_secret TOKEN "Paste existing token JSON (empty = log in via browser)"
            [[ -z $TOKEN || $TOKEN == \{*access_token*\} ]] && break
            warn "That does not look like an rclone token (expected complete JSON {...} with access_token — was the paste cut off?)."
            TOKEN=""
        done
    fi
    if [[ -n $TOKEN && $TOKEN != \{*access_token*\} ]]; then
        die "ONEDRIVE_TOKEN does not look like an rclone token (expected complete JSON {...} with access_token — was the paste cut off?)."
    fi
    if [[ -n $CLIENT_ID && -z $CLIENT_SECRET ]]; then
        warn "Client ID given without a client secret."
    fi

    # Without a graphical session rclone cannot open a browser here, so the
    # token has to come from "rclone authorize" on another machine.
    if [[ -z $TOKEN && -z ${DISPLAY:-}${WAYLAND_DISPLAY:-} ]]; then
        (( USE_DEFAULTS )) && die "No browser available here. Set ONEDRIVE_TOKEN to the output of 'rclone authorize \"onedrive\"' run on a machine with a browser."
        echo
        info "No graphical session detected, so the browser login can't run here."
        info "On any computer with a browser and rclone, run:"
        info "    rclone authorize \"onedrive\"${CLIENT_ID:+ \"<client_id>\" \"<client_secret>\"}"
        info "and paste the JSON it prints between the ---> and <--- markers."
        while [[ -z $TOKEN ]]; do
            read_secret TOKEN "Token JSON"
            if [[ -n $TOKEN && $TOKEN != \{*access_token*\} ]]; then
                warn "That does not look like a complete rclone token."; TOKEN=""
            fi
        done
    fi
}

# -----------------------------------------------------------------------------
# Drive lookup (Microsoft Graph)
# -----------------------------------------------------------------------------
GRAPH_ERR="" R_ID="" R_TYPE="" R_NAME=""

json_str() { sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p" | head -n1; }

# resolve_drive TOKEN_JSON [DRIVE_ID]
# Looks up DRIVE_ID, or the signed-in user's own OneDrive (/me/drive) when no
# ID is given. Sets R_ID, R_TYPE, R_NAME.  The access token is sent to curl on
# stdin (-H @-) so it never appears on a command line.
resolve_drive() {
    local at path resp code body
    GRAPH_ERR="" R_ID="" R_TYPE="" R_NAME=""
    at=$(json_str access_token <<<"$1")
    [[ -n $at ]] || { GRAPH_ERR="token has no access_token"; return 1; }
    if [[ -n ${2:-} ]]; then path="/drives/$2"; else path="/me/drive"; fi
    resp=$(printf 'Authorization: Bearer %s\n' "$at" \
        | curl -sS --max-time 30 -H @- -w '\n%{http_code}' \
            "https://graph.microsoft.com/v1.0${path}?\$select=id,driveType,name" 2>&1) \
        || { GRAPH_ERR="network error: ${resp##*$'\n'}"; return 1; }
    code=${resp##*$'\n'}; body=${resp%$'\n'*}
    if [[ $code != 200 ]]; then
        GRAPH_ERR="HTTP $code $(json_str message <<<"$body")"
        return 1
    fi
    R_ID=$(json_str id <<<"$body"); R_TYPE=$(json_str driveType <<<"$body"); R_NAME=$(json_str name <<<"$body")
    [[ -n $R_ID && -n $R_TYPE ]] || { GRAPH_ERR="unexpected response from Microsoft Graph"; return 1; }
}

# For a kept remote: make sure it points at the user's own drive (or the
# DRIVE_ID from setup.conf). Read-only — the fix is applied in phase 6.
FIX_DRIVE=no FIX_ID="" FIX_TYPE="" FIX_NAME=""
check_existing_drive() {
    command -v curl >/dev/null 2>&1 || { info "curl not installed yet — skipping drive check."; return 0; }
    info "Checking which drive '$REMOTE_NAME' points to ..."
    # Any rclone access refreshes an expired token in rclone.conf.
    timeout 60 rclone lsd "${REMOTE_NAME}:" --max-depth 1 >/dev/null 2>&1 \
        || { warn "The existing remote cannot access OneDrive — consider re-creating it."; return 0; }
    local show cur tok cur_name
    show=$(rclone config show "$REMOTE_NAME" 2>/dev/null) || return 0
    [[ $(sed -n 's/^type = //p' <<<"$show") == onedrive ]] || { info "Not a OneDrive remote — skipping drive check."; return 0; }
    cur=$(sed -n 's/^drive_id = //p' <<<"$show")
    tok=$(sed -n 's/^token = //p' <<<"$show")
    if ! resolve_drive "$tok" "$DRIVE_ID"; then
        warn "Could not look up the target drive ($GRAPH_ERR) — skipping drive check."
        return 0
    fi
    if [[ $cur == "$R_ID" ]]; then
        ok "Remote uses $( [[ -n $DRIVE_ID ]] && echo "drive" || echo "your own OneDrive") '$R_NAME'"
        return 0
    fi
    FIX_ID=$R_ID FIX_TYPE=$R_TYPE FIX_NAME=$R_NAME
    cur_name="unknown"
    resolve_drive "$tok" "$cur" && cur_name=$R_NAME
    tok="" show=""
    warn "Remote '$REMOTE_NAME' points to drive '$cur_name', not $( [[ -n $DRIVE_ID ]] && echo "DRIVE_ID from setup.conf" || echo "your own OneDrive") '$FIX_NAME'."
    if yesno "Switch it to '$FIX_NAME'?" yes; then FIX_DRIVE=yes; fi
}

# -----------------------------------------------------------------------------
# Phase 3: save configuration
# -----------------------------------------------------------------------------
save_conf() {
    step "Saving configuration"
    local k changed=0
    for k in "${PROMPT_KEYS[@]}"; do
        if [[ ${ORIG[$k]} != "${!k}" ]]; then
            [[ -w $CONF_FILE ]] || die "Config file is not writable: $CONF_FILE"
            WRITES_STARTED=1
            conf_set "$k" "${!k}"
            ok "$k = ${!k}"
            changed=1
        fi
    done
    (( changed )) && ok "Updated $CONF_FILE" || ok "No changes — $CONF_FILE left untouched"
}

# -----------------------------------------------------------------------------
# Phase 4: dependencies
# -----------------------------------------------------------------------------
pkg_install() {
    case $PKG_MGR in
        apt-get) sudo apt-get update -qq && sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
        dnf)     sudo dnf install -y "$@" ;;
        yum)     sudo yum install -y "$@" ;;
        pacman)  sudo pacman -S --needed --noconfirm "$@" ;;
        zypper)  sudo zypper --non-interactive install "$@" ;;
        *)       return 1 ;;
    esac
}

install_rclone_script() {
    command -v curl >/dev/null 2>&1 || pkg_install curl || return 1
    local tmp; tmp=$(mktemp) || return 1
    curl -fsSL https://rclone.org/install.sh -o "$tmp" || { rm -f "$tmp"; return 1; }
    local rc=0
    sudo bash "$tmp" || rc=$?
    rm -f "$tmp"
    # install.sh exits 3 when the latest version is already installed
    (( rc == 0 || rc == 3 ))
}

install_deps() {
    step "Installing dependencies"
    if (( NEED_RCLONE || NEED_FUSE || NEED_CURL )); then
        WRITES_STARTED=1
        info "sudo is needed to install packages."
        sudo -v || die "sudo authentication failed."
    fi

    if (( NEED_FUSE )); then
        pkg_install fuse3 || die "Failed to install fuse3 with $PKG_MGR."
        command -v fusermount3 >/dev/null 2>&1 || die "fuse3 installed but 'fusermount3' not found."
    fi
    ok "fuse3: $(fusermount3 -V 2>&1 | head -n1)"

    if (( NEED_CURL )); then
        pkg_install curl || die "Failed to install curl with $PKG_MGR."
        command -v curl >/dev/null 2>&1 || die "curl installed but not found on PATH."
    fi
    ok "curl: $(curl --version | head -n1 | cut -d' ' -f1-2)"

    if (( NEED_RCLONE )); then
        case $RCLONE_INSTALL_METHOD in
            package) pkg_install rclone || die "Failed to install rclone with $PKG_MGR." ;;
            script)  install_rclone_script || die "Failed to install rclone via rclone.org/install.sh." ;;
            *)       pkg_install rclone || { warn "Distro package failed/unavailable — trying rclone.org install script."
                                             install_rclone_script || die "Failed to install rclone."; } ;;
        esac
        hash -r
    fi
    command -v rclone >/dev/null 2>&1 || die "rclone is not on PATH after installation."
    rclone version >/dev/null 2>&1 || die "rclone is installed but does not run ('rclone version' failed)."
    ok "rclone: $(rclone version | head -n1)"

    if [[ ! -e /dev/fuse ]]; then
        WRITES_STARTED=1
        warn "/dev/fuse missing — loading the fuse kernel module."
        sudo modprobe fuse || die "Could not load the fuse kernel module (/dev/fuse missing)."
    fi
    [[ -r /dev/fuse && -w /dev/fuse ]] || die "/dev/fuse is not accessible for user $USER."
    ok "/dev/fuse accessible"
}

# -----------------------------------------------------------------------------
# Phase 5: folders
# -----------------------------------------------------------------------------
create_dirs() {
    step "Creating folders"
    WRITES_STARTED=1
    local d
    for d in "$MOUNT_PATH" "$CACHE_PATH"; do
        if [[ -d $d ]]; then
            ok "Exists: $d"
        else
            mkdir -p -- "$d" || die "Cannot create folder: $d"
            ok "Created: $d"
        fi
    done
    mountpoint -q "$MOUNT_PATH" || [[ -w $MOUNT_PATH ]] || die "Mount folder is not writable: $MOUNT_PATH"
    [[ -w $CACHE_PATH ]] || die "Cache folder is not writable: $CACHE_PATH"
    chmod 700 "$CACHE_PATH" 2>/dev/null || warn "Could not restrict permissions on $CACHE_PATH"
}

# -----------------------------------------------------------------------------
# Phase 6: rclone remote
# -----------------------------------------------------------------------------
RCLONE_CONF=""

backup_rclone_conf() {
    [[ -f $RCLONE_CONF ]] || return 0
    local bak; bak="$RCLONE_CONF.bak.$(date +%Y%m%d-%H%M%S)"
    cp -p "$RCLONE_CONF" "$bak" || die "Cannot back up $RCLONE_CONF"
    ok "Backed up rclone config to $bak"
}

configure_remote() {
    step "Configuring rclone remote '$REMOTE_NAME'"
    RCLONE_CONF=$(rclone config file 2>/dev/null | tail -n1)
    [[ -n $RCLONE_CONF ]] || die "Could not determine rclone config file location."

    if [[ $REMOTE_EXISTS == yes && $RECONFIGURE_REMOTE == no ]]; then
        if [[ $FIX_DRIVE == yes ]]; then
            WRITES_STARTED=1
            backup_rclone_conf
            rclone config update "$REMOTE_NAME" "drive_id=$FIX_ID" "drive_type=$FIX_TYPE" \
                config_refresh_token=false --non-interactive >/dev/null \
                || die "Failed to switch remote '$REMOTE_NAME' to drive '$FIX_NAME'."
            ok "Remote now points to '$FIX_NAME' ($FIX_TYPE)"
        else
            ok "Keeping existing remote"
        fi
    else
        WRITES_STARTED=1
        # 1. Log in (unless a token was provided). rclone prints the login URL
        #    and the token on stdout: show everything except the token, which
        #    is captured into memory only.
        if [[ -z $TOKEN ]]; then
            local -a auth_args=()
            [[ -n $CLIENT_ID ]] && auth_args=("$CLIENT_ID" "$CLIENT_SECRET")
            info "Opening a browser for the Microsoft login (rclone authorize) ..."
            if ! TOKEN=$(rclone authorize onedrive ${auth_args[@]+"${auth_args[@]}"} 2>&1 | awk '
                    /^[[:space:]]*\{.*access_token.*\}[[:space:]]*$/ { print; next }
                    /Paste the following into your remote machine|<---End paste/ { next }
                    { print "    " $0 > "/dev/stderr"; fflush("/dev/stderr") }'); then
                TOKEN=""
                die "Microsoft login failed or was cancelled."
            fi
            [[ $TOKEN == \{*access_token*\} ]] || die "rclone authorize did not return a token."
            ok "Logged in"
        fi

        # 2. Find the drive: the user's own OneDrive, or DRIVE_ID if configured.
        info "Looking up $( [[ -n $DRIVE_ID ]] && echo "drive $DRIVE_ID" || echo "your own OneDrive") ..."
        resolve_drive "$TOKEN" "$DRIVE_ID" \
            || die "Could not look up the drive via Microsoft Graph ($GRAPH_ERR). A pasted token may have expired — get a fresh one with: rclone authorize \"onedrive\""
        ok "Drive: '$R_NAME' ($R_TYPE)"

        # 3. Write the remote with rclone's own config machinery.
        mkdir -p "$(dirname "$RCLONE_CONF")" || die "Cannot create $(dirname "$RCLONE_CONF")"
        backup_rclone_conf
        if [[ $REMOTE_EXISTS == yes ]]; then
            rclone config delete "$REMOTE_NAME" || die "Failed to remove existing remote '$REMOTE_NAME'."
            ok "Removed old remote definition"
        fi
        local -a args=("drive_id=$R_ID" "drive_type=$R_TYPE" "token=$TOKEN")
        [[ -n $CLIENT_ID     ]] && args+=("client_id=$CLIENT_ID")
        [[ -n $CLIENT_SECRET ]] && args+=("client_secret=$CLIENT_SECRET")
        rclone config create "$REMOTE_NAME" onedrive "${args[@]}" \
            config_refresh_token=false --non-interactive >/dev/null \
            || { args=(); die "rclone config create failed."; }

        # Secrets are no longer needed — drop them from memory.
        args=() TOKEN="" CLIENT_ID="" CLIENT_SECRET=""
        unset ONEDRIVE_TOKEN ONEDRIVE_CLIENT_ID ONEDRIVE_CLIENT_SECRET
        rclone listremotes | grep -Fxq "${REMOTE_NAME}:" || die "Remote '$REMOTE_NAME' was not created."
        chmod 600 "$RCLONE_CONF" 2>/dev/null || true
        ok "Remote '$REMOTE_NAME' written to $RCLONE_CONF"
    fi

    info "Verifying access to OneDrive ..."
    local out
    if ! out=$(timeout 90 rclone lsd "${REMOTE_NAME}:" --max-depth 1 2>&1); then
        printf '%s\n' "$out" | tail -n 5 | sed 's/^/    /' >&2
        die "Cannot access OneDrive through remote '$REMOTE_NAME'. Re-run setup and choose to re-create the remote."
    fi
    ok "OneDrive reachable ($(printf '%s\n' "$out" | grep -c . || true) top-level folders)"
}

# -----------------------------------------------------------------------------
# Phase 7: systemd user service
# -----------------------------------------------------------------------------
# Quote an argument for systemd's ExecStart= syntax.
sd_quote() {
    local s=$1
    s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//%/%%}; s=${s//\$/\$\$}
    printf '"%s"' "$s"
}

create_service() {
    local unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    local unit="$unit_dir/$SERVICE_NAME.service"

    if [[ $AUTOSTART != yes ]]; then
        step "systemd service"
        info "Autostart = no → service not created."
        [[ -f $unit ]] && warn "An existing $unit was left untouched (run ./uninstall.sh to remove it)."
        return 0
    fi

    step "Creating systemd user service '$SERVICE_NAME'"
    WRITES_STARTED=1
    local rclone_bin fusermount_bin tmp
    rclone_bin=$(command -v rclone); fusermount_bin=$(command -v fusermount3)
    mkdir -p "$unit_dir" || die "Cannot create $unit_dir"

    tmp=$(mktemp "$unit_dir/.${SERVICE_NAME}.XXXXXX") || die "Cannot write to $unit_dir"
    cat >"$tmp" <<EOF
# Generated by onedrive-linux/setup.sh on $(date '+%Y-%m-%d %H:%M').
# Re-run setup.sh to regenerate; manual edits will be overwritten.
[Unit]
Description=OneDrive mount (rclone remote '$REMOTE_NAME') at $MOUNT_PATH
Documentation=https://rclone.org/commands/rclone_mount/
Wants=network-online.target
After=network-online.target

[Service]
Type=notify
ExecStartPre=/usr/bin/env mkdir -p $(sd_quote "$MOUNT_PATH")
ExecStart=$(sd_quote "$rclone_bin") mount $(sd_quote "${REMOTE_NAME}:") $(sd_quote "$MOUNT_PATH") \\
    --config $(sd_quote "$RCLONE_CONF") \\
    --cache-dir $(sd_quote "$CACHE_PATH") \\
    --vfs-cache-mode $(sd_quote "$VFS_CACHE_MODE") \\
    --vfs-cache-max-size $(sd_quote "$VFS_CACHE_MAX_SIZE") \\
    --vfs-cache-max-age $(sd_quote "$VFS_CACHE_MAX_AGE") \\
    --dir-cache-time $(sd_quote "$DIR_CACHE_TIME") \\
    --log-level INFO $EXTRA_MOUNT_ARGS
ExecStop=$(sd_quote "$fusermount_bin") -uz $(sd_quote "$MOUNT_PATH")
Restart=on-failure
RestartSec=15

[Install]
WantedBy=default.target
EOF
    mv -f "$tmp" "$unit" || { rm -f "$tmp"; die "Cannot write $unit"; }
    ok "Wrote $unit"

    if command -v systemd-analyze >/dev/null 2>&1; then
        local v
        v=$(systemd-analyze --user verify "$unit" 2>&1 | grep -F "$SERVICE_NAME" || true)
        [[ -z $v ]] && ok "Unit file verified" || warn "systemd-analyze reported: $v"
    fi

    systemctl --user daemon-reload || die "systemctl --user daemon-reload failed."
    systemctl --user enable "$SERVICE_NAME.service" >/dev/null 2>&1 \
        || die "Failed to enable $SERVICE_NAME.service."
    ok "Enabled (starts automatically at login)"

    info "Starting service ..."
    if ! systemctl --user restart "$SERVICE_NAME.service"; then
        journalctl --user -u "$SERVICE_NAME.service" -n 20 --no-pager 2>/dev/null | sed 's/^/    /' >&2 || true
        die "Service failed to start. See: journalctl --user -u $SERVICE_NAME -e"
    fi

    local i
    for (( i = 0; i < 30; i++ )); do
        mountpoint -q "$MOUNT_PATH" && break
        sleep 1
    done
    if ! mountpoint -q "$MOUNT_PATH"; then
        journalctl --user -u "$SERVICE_NAME.service" -n 20 --no-pager 2>/dev/null | sed 's/^/    /' >&2 || true
        die "Service started but $MOUNT_PATH is not mounted."
    fi
    ls "$MOUNT_PATH" >/dev/null 2>&1 || die "$MOUNT_PATH is mounted but cannot be listed."
    ok "OneDrive mounted at $MOUNT_PATH"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    while (( $# )); do
        case $1 in
            -y|--defaults) USE_DEFAULTS=1 ;;
            -c|--config)   [[ $# -ge 2 ]] || die "--config needs a file"; CONF_FILE=$(expand_path "$2"); shift ;;
            -h|--help)     usage; exit 0 ;;
            *)             usage >&2; die "Unknown option: $1" ;;
        esac
        shift
    done

    printf '%sonedrive-linux setup%s  %s(config: %s)%s\n' "$C_B" "$C_0" "$C_D" "$CONF_FILE" "$C_0"
    load_conf

    preflight
    collect
    save_conf
    install_deps
    create_dirs
    configure_remote
    create_service

    step "Done"
    ok "OneDrive remote : ${REMOTE_NAME}:"
    ok "Mount folder    : $MOUNT_PATH"
    if [[ $AUTOSTART == yes ]]; then
        info "Status : systemctl --user status $SERVICE_NAME"
        info "Logs   : journalctl --user -u $SERVICE_NAME -f"
        info "Stop   : systemctl --user stop $SERVICE_NAME"
    else
        info "Mount manually with:"
        info "  rclone mount ${REMOTE_NAME}: \"$MOUNT_PATH\" --cache-dir \"$CACHE_PATH\" --vfs-cache-mode $VFS_CACHE_MODE --daemon"
        info "Unmount with: fusermount3 -u \"$MOUNT_PATH\""
    fi
}

main "$@"
