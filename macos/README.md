# Dockswain for macOS

A **menu-bar app** for managing Docker on a remote server over SSH — the macOS
counterpart of the Linux KDE Plasma widget in the [repository root](../README.md).
Live container list with start/stop/restart/remove, auto-following logs, "exec a
shell into a container", `docker compose` up/down, and a one-click "open an SSH
terminal on the server" button. It lives in the menu bar with a running/total badge.

## Why this is a separate app (not the same folders)

The Linux version is a **KDE Plasma 6 plasmoid**: its entire UI is built on
`org.kde.plasma.*` and `org.kde.kirigami`, hosted by `plasmashell` and installed
with `kpackagetool6`. None of that exists on macOS, so the widget can't be "moved"
by reorganizing folders — the UI had to be rewritten natively in **SwiftUI**
(a draggable, edge-dockable menu-bar panel). What carries over is the proven backend approach: a small bash
helper that runs docker over a multiplexed SSH connection and prints normalized
output the app parses.

The helper, [`Sources/Dockswain/Backend/dockswain-mac.sh`](Sources/Dockswain/Backend/dockswain-mac.sh),
is the macOS port of the Linux `dockswain.sh`, with the Linux-only bits swapped out:

| Linux original            | macOS port                                    |
|---------------------------|-----------------------------------------------|
| `secret-tool` / KWallet   | macOS **Keychain** (via the Security framework) |
| Konsole / Kate            | **Terminal.app** (via `osascript`)            |
| `find -printf` (local)    | local pane listed natively in Swift           |
| `/run/user/<uid>` socket  | per-user `$TMPDIR` control socket             |
| Remmina/FileZilla import  | **`~/.ssh/config`** import                    |

## Requirements

- macOS 13 (Ventura) or newer
- Xcode command line tools (`xcode-select --install`) — provides `swift`
- `jq` and `ssh` — both ship with recent macOS / Xcode tools
- **No extra tools for password auth.** Passwords are fed to ssh through OpenSSH's
  own `SSH_ASKPASS` mechanism (needs OpenSSH 8.4+, which macOS has shipped since
  Big Sur), so there's nothing like `sshpass` to install.
- On the **server**: `docker`, and an SSH user that can run it (docker group,
  rootless, or set the docker command to `sudo docker` in Settings).

## Build & run

Quickest (runs from the terminal, look for the ⚓ in the menu bar):

```sh
swift run
```

Build a real, installable menu-bar app:

```sh
./make-signing-cert.sh      # run ONCE: stable local signing (see below)
./build-app.sh
open Dockswain.app          # or: cp -R Dockswain.app /Applications/
```

`make-signing-cert.sh` creates a one-time, self-signed code-signing identity in your
login keychain. Without it the app is ad-hoc signed, so every rebuild looks like a
new app to macOS and it re-asks permission for the Keychain item holding your SSH
passwords — even after you click **Always Allow**. Signing with a fixed identity
makes "Always Allow" stick across rebuilds. (It's local-only; it has nothing to do
with Apple Developer signing or notarization.) The first time the app reads a stored
password you'll still get one macOS prompt asking for your **Mac login password** —
that unlocks the keychain; click **Always Allow** and you won't see it again.

The app has **no Dock icon** — it's menu-bar only. Quit it from its own ⚓ menu
(power button) or with the menu bar item.

## Using it

1. Click the ⚓ menu bar item → gear icon (**Settings**).
2. **Add a server** (label, user, host, port) or **Import from `~/.ssh/config`**.
   - **SSH key** auth: leave the key path blank to use your ssh-agent/config, or
     point it at a key file. Passphrase-protected keys must already be loaded into
     `ssh-agent` (`ssh-add ~/.ssh/id_ed25519`), since polls are non-interactive.
   - **Password** auth: the password is stored in your **Keychain** (never in a
     file or on a command line) and fed to ssh through its built-in `SSH_ASKPASS`
     helper at connect time. No extra tools to install.
3. Use **Test connection** to confirm, then **Save**.
4. Pick the server from the dropdown at the top. Containers list live and refresh
   on an interval (Settings → Refresh every). Per row: start/stop, restart, logs,
   exec a shell (opens Terminal.app), and remove (confirmed).

Authentication is non-interactive and the SSH connection is multiplexed
(`ControlPersist`), so the first connection stays warm and every poll/action after
it reuses the same socket and returns in milliseconds.

## Features

- **Containers:** live list with start/stop/restart/remove, **filter bar** (search +
  running-only), **group by network**, **pin to top**, auto-following **logs**, exec a
  shell (Terminal.app), and a running/total menu-bar badge.
- **Live CPU/memory stats** (optional, off by default — `docker stats` is slower).
- **Compose projects:** `docker compose` up/down and a peek at the compose file.
- **Disk & cleanup:** docker data-root usage bar, `docker system df` breakdown, safe
  one-click prunes (build cache / dangling images / stopped containers, each
  confirmed), and per-container log sizes with a truncate button.
- **File manager (SFTP):** Local ↔ Remote panes, navigate/mkdir/rename/delete, and
  upload/download that reuses the warm SSH master (scp, no second password). Local
  listing is native; remote is over SSH.
- **Nginx:** browse `/etc/nginx` sites, enable/disable, view/**edit** a config inline
  (written back over SSH), run `nginx -t`, and reload.
- **Certbot SSL:** list certificates and issue a new one with `certbot --nginx`
  (optional HTTP→HTTPS redirect).
- **Servers:** add by hand or import from `~/.ssh/config`; passwords in the Keychain.

Everything runs over one multiplexed SSH connection, so polls and actions return in
milliseconds and interactive terminals/transfers don't re-authenticate.

## License

MIT (same as the Linux original).
