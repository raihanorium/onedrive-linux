#!/usr/bin/env bash
# Remove what setup.sh created: service, mount, (optionally) remote and cache.
# rclone and fuse3 packages are NOT removed.
set -Euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONF_FILE="${1:-$SCRIPT_DIR/setup.conf}"
[[ -r $CONF_FILE ]] || { echo "Config file not found: $CONF_FILE" >&2; exit 1; }
# shellcheck source=setup.conf
source "$CONF_FILE"

expand_path() { case $1 in "~") echo "$HOME" ;; "~/"*) echo "$HOME/${1#"~/"}" ;; *) echo "$1" ;; esac; }
yesno() { local a; read -r -p "  $1 [y/N]: " a; [[ ${a,,} == y || ${a,,} == yes ]]; }

MOUNT_PATH=$(expand_path "$MOUNT_DIR")
CACHE_PATH=$(expand_path "$CACHE_DIR")
UNIT="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/$SERVICE_NAME.service"

echo "This removes the OneDrive service '$SERVICE_NAME' and unmounts $MOUNT_PATH."
yesno "Continue?" || exit 0

if [[ -f $UNIT ]]; then
    systemctl --user disable --now "$SERVICE_NAME.service" 2>/dev/null || true
    rm -f "$UNIT" && systemctl --user daemon-reload && echo "  ✔ Service removed"
else
    echo "  - No service file at $UNIT"
fi

if mountpoint -q "$MOUNT_PATH" 2>/dev/null; then
    fusermount3 -uz "$MOUNT_PATH" && echo "  ✔ Unmounted $MOUNT_PATH" || echo "  ! Could not unmount $MOUNT_PATH" >&2
fi
if [[ -d $MOUNT_PATH ]] && rmdir "$MOUNT_PATH" 2>/dev/null; then echo "  ✔ Removed empty folder $MOUNT_PATH"; fi

if [[ -d $CACHE_PATH ]] && yesno "Delete cache folder $CACHE_PATH (unsynced changes will be lost)?"; then
    rm -rf -- "$CACHE_PATH" && echo "  ✔ Cache removed"
fi

if command -v rclone >/dev/null && rclone listremotes 2>/dev/null | grep -Fxq "${REMOTE_NAME}:" \
   && yesno "Delete rclone remote '$REMOTE_NAME' (you'd need to log in again)?"; then
    rclone config delete "$REMOTE_NAME" && echo "  ✔ Remote removed"
fi
echo "Done."
