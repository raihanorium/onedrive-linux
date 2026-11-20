# onedrive-linux

Mounts your own Microsoft OneDrive as a folder on Linux using rclone and FUSE3, with an optional systemd user service that mounts it at login.

```bash
./setup.sh              # interactive: press Enter to accept the default in brackets
./setup.sh --defaults   # no prompts; uses the values in setup.conf
./uninstall.sh          # removes the service and mount; asks before deleting the cache or remote
```

- **What it does:** installs rclone, fuse3 and curl if missing, creates the mount and cache folders, logs you in through the browser, sets up the rclone remote, and creates the service. Every step is checked, and setup is safe to re-run.
- **Config:** `setup.conf` holds the team defaults (remote name, folders, service name, autostart). Values you change at the prompts are saved back to it.
- **Secrets:** the token, client ID and client secret are never saved in `setup.conf`. Enter them at the hidden prompts, or set `ONEDRIVE_TOKEN`, `ONEDRIVE_CLIENT_ID` or `ONEDRIVE_CLIENT_SECRET` in the environment. They're passed straight to rclone.
- **Drive:** setup mounts the signed-in user's own OneDrive ("My files") automatically and offers to fix a remote that points at another drive. Set `DRIVE_ID` to force a specific drive.
- **No browser here** (e.g. SSH): run `rclone authorize "onedrive"` on another machine and paste the token when asked.
- **Manage the service:** `systemctl --user status|restart|stop rclone-onedrive`. Logs: `journalctl --user -u rclone-onedrive -f`.
- **Mount at boot without logging in:** `sudo loginctl enable-linger $USER`

Run as your normal user, not with sudo. Tested with rclone 1.60 on Ubuntu (apt); dnf, yum, pacman and zypper are also supported.
