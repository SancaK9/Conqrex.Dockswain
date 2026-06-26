# Dockswain

A KDE Plasma 6 widget (plasmoid) for managing Docker on a remote server over SSH.
You get a live container list with start/stop/restart, logs, "exec a shell into a
container", and `docker compose` up/down, plus a one-click "open Konsole on the
server" button. It runs either as a panel icon (with a running/total badge) or as a
desktop widget showing the full list.

I wrote it for CachyOS but there's nothing distro-specific about it.

## How it works

There's a helper script, `package/contents/code/dockswain.sh`, that runs the
docker commands on the selected server over SSH and prints back normalized JSON. The
QML parses that into the list you see.

SSH is key-based and non-interactive (`BatchMode=yes`), so a poll never hangs waiting
on a password prompt, and it's multiplexed with `ControlPersist`, so the first
connection stays warm and every poll/action after it reuses the same socket and comes
back in a few milliseconds.

```
ssh -o BatchMode=yes -o ControlMaster=auto -o ControlPersist=60 … user@host \
    'docker ps -a --no-trunc --format "{{json .}}"'
```

Passwords never go into a config file or onto a command line. They stay in your
KWallet/keyring and the helper looks them up when it needs to connect. Server details
are imported straight from your Remmina SSH profiles (`protocol`, `server`,
`username`, `ssh_privatekey`). The encrypted `password` field inside the `.remmina`
file is never touched; for password servers the widget reuses whatever password
Remmina itself stored in the keyring (Secret Service schema `org.remmina.Password`,
matched by the profile filename), so an imported server just connects with nothing to
copy-paste.

## Authentication

Every server is either password auth or SSH-key auth, set per server under
Settings → Servers. Importing from Remmina guesses the mode for you.

**Password** is the easy path. It uses `sshpass`, with the password kept in your
KWallet/keyring via `secret-tool` (again, never in a file or on a command line). If
you imported the server from Remmina and Remmina had already saved its password, the
widget picks that up automatically and there's nothing to set up; the server row just
says "Using Remmina password". For a server you added by hand, or to override the
Remmina one, go to Settings → Servers → Set password. A small Konsole window pops up
and asks you to type it once. Because the SSH connection is multiplexed, that password
only opens the first connection; everything after reuses it.

**SSH key** auth needs the key to be usable without a prompt, since the poller runs
non-interactively. So either an unencrypted key, or a passphrase-protected key that's
already loaded into `ssh-agent`:

```sh
eval "$(ssh-agent)"        # if no agent is running in your session
ssh-add ~/.ssh/id_ed25519  # unlock the key once for the session
```

Either way, `docker` has to exist on the remote and your user has to be able to run
it: in the `docker` group, rootless, or point the widget's docker command at
`sudo docker`. If auth fails you get a readable hint instead of a spinner.

## Install

```sh
./install.sh
```

Then right-click the desktop or panel → Add Widgets → Dockswain. Open its
Settings → Servers → Import from Remmina (or add a server by hand). After changing the
code, reload plasmashell:

```sh
kquitapp6 plasmashell && kstart plasmashell
```

## Install with pacman (Arch / CachyOS)

> Not on the AUR yet. New AUR account registration is disabled on Arch's side at
> the moment, so I can't publish there. When it reopens it'll go up on the AUR too
> (then it's just `paru -S dockswain`). Until then, install it straight from the
> GitHub release repo below.

Add this to `/etc/pacman.conf`:

```ini
[dockswain]
SigLevel = Optional TrustAll
Server = https://github.com/SancaK9/Conqrex.Dockswain/releases/download/arch-repo
```

Then sync and install:

```sh
sudo pacman -Syu dockswain
```

Updates ride along with a normal `sudo pacman -Syu`. The packages aren't signed yet,
which is why the repo line needs `SigLevel = Optional TrustAll`. After it's installed,
add the widget the usual way: right-click the panel or desktop → Add Widgets → Dockswain.

## Using it

- **Tabs** across the top of the popup: each open server is its own tab with its own
  live connection, so you can keep several servers connected and refreshing at once
  and switching between them is instant. The **+** opens another configured server in
  a new tab and the **×** closes one. Open tabs survive a restart. (Only the tab
  you're looking at fetches CPU/memory stats; the others keep refreshing their list.)
- **Filter bar:** a search box and a running-only toggle. Exited containers are hidden
  by default and running ones float to the top, with a footer telling you how many are
  hidden. Search matches name/image/state as you type.
- Each container has a **logs** button and a **⋯ menu**: start/stop, restart, exec
  (which opens Konsole running `docker exec -it … sh`), pin to top, and remove (with a
  confirmation). The action icons stay dim until you hover the row.
- **Favorites / pin to top:** star a network header to keep that group at the top, or
  pin an individual container from its ⋯ menu, so the things you actually care about
  don't scroll off. Pins stick around.
- **Logs auto-follow:** the inline log view re-fetches every couple of seconds and
  stays pinned to the bottom, so there's no refresh button. A Follow toggle pauses it,
  and "Follow live in Konsole" hands you a real `docker logs -f` stream.
- **Compose projects:** a section listing your `docker compose` projects with up/down
  and a files button to View a project's compose file inline (and then Edit in Kate
  over SSH). Docker Swarm stacks show up here too if the server is a swarm manager,
  listed with their service count and a Remove stack action (`docker stack rm`). Up and
  files are hidden for stacks since a stack has no local compose file to open.
- Swarm tasks normally sit on `ingress`/`docker_gwbridge` plus their app network, which
  makes them jump around between polls. They're grouped under their app network instead
  so they stay put.
- **Group by network** (the tree button): break the container list into sections by
  docker network, each header showing the network name and how many visible containers
  are on it. Toggle it off for a flat list; the default lives in Settings.
- **Disk usage & cleanup** (the disk button): how much of the docker data root's
  filesystem is in use (used / free / total with a colored bar), plus `docker system
  df` broken out by images, containers, local volumes and build cache, each with its
  size and how much is reclaimable. One-click safe cleanups, each confirmed first:
  prune build cache, dangling images, and stopped containers. Volumes are listed but
  never pruned, which keeps your database data safe; tagged images and `-a`/`--volumes`
  are deliberately left out. Below that, every container's JSON log file is listed by
  size, biggest first, with a running total — so the one log quietly eating 30 GB is
  the first thing you see — and a Truncate button empties it to zero after a confirm
  that tells you how much you're discarding. Reading and truncating those root-owned
  files needs the SSH user to be root, or the docker command set to `sudo docker`.
- **Nginx** (the globe button): browse `/etc/nginx`. View or edit `nginx.conf` and
  each site (`sites-available`/`conf.d`), enable/disable sites, run `nginx -t`, and
  reload. Editing opens the file in your editor over the existing SSH connection, so
  no second password, and writes it back on save/close. Each site shows its domains
  (`server_name`) and a lock icon if it already has a TLS block.
  - **New website** (the ➕ button): generate a fresh server block from a short form,
    either a reverse proxy (`proxy_pass` to a container or host:port, with the
    WebSocket upgrade headers) or a static site (`root` + `try_files`, optionally
    creating the web root with a placeholder `index.html`). It gets written to the
    right place for your layout (`sites-available` + symlink, or `conf.d/*.conf`), and
    you can Test and Reload from the same form.
  - **SSL with certbot** (the lock button on a site, or Get SSL right after creating
    one): grabs and installs a Let's Encrypt certificate with `certbot --nginx` for the
    site's domains, with an optional HTTP→HTTPS redirect. No email is registered
    (`--register-unsafely-without-email`) and certbot reloads nginx itself on success.
    A Certificates list shows each cert's domains and expiry date (read from `certbot
    certificates`). You'll need `certbot` and its nginx plugin on the server.
- **File manager** (the folder button): a dual-pane SFTP browser, your local machine
  on one side and the remote server on the other, Dolphin-style rows with mime icons,
  size and modified date. It piggybacks on the widget's warm SSH connection, so again
  no second password.
  - Move files by dragging between the panes (or the per-row ↑/↓ buttons, or the
    right-click menu). You can also drop files straight from Dolphin onto the remote
    pane to upload. Transfers go through rsync when it's available on both ends (with
    live percent and speed) or fall back to scp, and show up in a transfer queue with
    progress and a cancel button.
  - **Pin** (📌): when the widget lives in a panel, the popup normally closes the moment
    it loses focus, which is annoying when you're trying to drag files in from Dolphin.
    Hit Pin to keep it open, and click again (or close it) to unpin.
  - **Favorite folders** on either side (the ☆ button, or right-click → Add to
    favorites). Get back to them from the bookmarks dropdown in each pane's toolbar
    (works at any width) or from the Places strip when the pane is wide enough to show
    it. Local favorites are global; remote ones are per-server.
  - **Compare & sync**, FileZilla-style: turn on Compare to color-code the two folders
    (only-on-one-side, size differs, newer here/there), then narrow it to Only new,
    Only size-differs, or Newer only and Transfer →/← everything that matches.
  - Make folders, rename, delete (deletes are confirmed, and protected paths like `/`
    or your home are refused). The layout is responsive: side-by-side when the popup is
    wide, a Local/Remote toggle when it's narrow (popup size is a setting).
- **Open Konsole → SSH** just drops you into a terminal on the server.
- **CPU/memory stats** are optional and off by default, since `docker stats` is slower;
  when on, they poll on their own slower interval.

> Remote editing reuses the SSH connection you already have open (the one your stored
> password opened). It pulls the file into a temp copy, opens it in your editor, and
> writes it back over SSH on every save and on close. No second password prompt.
> Connecting as root edits `/etc/nginx/*` in place.

## Settings

- **Servers** — add/remove servers (label, `user@host`, port, key or password auth),
  or Import from Remmina / Import from FileZilla. (FileZilla import is SFTP sites only;
  plain FTP sites are skipped since the widget talks SSH. Imported password sites get
  their saved password copied into your keyring so they work right away.)
- **General** — refresh interval, stats on/off and its interval, the docker command
  (`docker` or `sudo docker`), terminal, whether to confirm destructive actions, SSH
  connect timeout, 24-hour time, the hide-exited and group-by-network defaults, log
  tail length and follow interval, the nginx directory, the editor (kate), and the file
  manager options: starting local directory, transfer tool (`auto`/`rsync`/`scp`),
  popup size, confirm-delete, and show-hidden-files.

## Security & notes

- When a password is used it lives only in your KWallet/keyring, never in a config file
  and never on a command line. The helper looks it up at connect time and pipes it into
  `sshpass` through an env var. For Remmina-imported servers it just reuses the password
  Remmina stored. `StrictHostKeyChecking=accept-new` lets new hosts in but rejects a
  changed host key (so you still get MITM protection).
- You can't embed a real interactive terminal inside a Plasma QML widget, so shells
  open in an external Konsole. That's the usual way Plasma apps handle it.
- It's built on the same executable-data-source pattern as the Conqrex Claude widget.
  The container side of it was inspired by
  [plasmoid-dockio](https://github.com/imoize/plasmoid-dockio) and
  [docker-companion](https://github.com/results-may-vary-org/docker-companion); the SSH
  part is what's different here.

## Support

If Dockswain saves you a few trips to a terminal, you can buy me a coffee. It's
not expected, but it's appreciated and helps me keep working on it.

[![Buy Me A Coffee](https://www.buymeacoffee.com/assets/img/custom_images/orange_img.png)](https://www.buymeacoffee.com/sancak)

## License

MIT
