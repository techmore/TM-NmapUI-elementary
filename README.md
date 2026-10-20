# Network Scanner for elementary OS

The native elementary OS front end for [TM-NmapUI](https://github.com/techmore/TM-NmapUI):
a Granite / GTK 4 window, a Wingpanel indicator and a per-user scanner service.

| Piece | What it is |
|---|---|
| `src/` | **Network Scanner** (`io.github.techmore.NmapUI`), a Vala app. Pantheon headerbar with segmented tabs, a live status chip, system light/dark, scan-finished notifications, report download toasts, and a Granite placeholder that starts the service when it is down. |
| `indicator/` | Wingpanel indicator: scan state and progress, network facts, hosts/changes/critical, alerts, and the device list from the latest scan. |
| `helper/nmapui-summary` | One-shot JSON summary of the local scanner (loopback API only) used by the indicator. |
| `data/` | Desktop entry, AppStream metadata, icons and the `nmapui.service` user-unit template. |
| `scripts/` | `install.sh` (build + install the app and indicator), `install-backend.sh` (clone the engine, create its venv, install the service), `snapshot.sh` (headless renders for review). |

The scanner engine itself is not in this repository. It is the Flask application on
TM-NmapUI's `main` branch, running on this computer as `nmapui.service`, bound to `127.0.0.1:9000`.
This app never implements a second scanning engine; it gives the existing one a native home.

## Install

On elementary OS 9 (the Wingpanel indicator needs `wingpanel-9`); the app itself also builds on elementary OS 8 with `-Dindicator=false`:

```bash
git clone https://github.com/techmore/TM-NmapUI-elementary.git
cd TM-NmapUI-elementary
scripts/install.sh
```

That builds and installs the app into `~/.local`, installs the Wingpanel indicator
system-wide (sudo), pins **Network Scanner** to the dock, and runs `scripts/install-backend.sh`,
which clones TM-NmapUI into `~/.local/share/nmapui/app`, creates its virtual environment,
installs Chromium for PDF reports, and enables the loopback-only user service.

- `scripts/install.sh --no-indicator` skips the Wingpanel module; `--no-backend` skips the engine.
- `NMAPUI_APP_DIR=~/Projects/TM-NmapUI scripts/install-backend.sh` runs the service from an existing checkout.
- `NMAPUI_REF=<branch|tag|sha> scripts/install-backend.sh` pins the engine revision.
- The indicator loads at the next login; the installer never restarts Wingpanel.
- Unprivileged scans use connect mode. SYN/OS/ARP scans need TM-NmapUI's root service
  (`packaging/ubuntu/install-service.sh`); nothing here grants raw-socket capabilities.

Data stays private under `~/.local/share/nmapui` (engine) and `~/.local/share/nmapui-elementary`
(web session and cookies). Remove everything with:

```bash
systemctl --user disable --now nmapui.service
rm -rf ~/.config/systemd/user/nmapui.service ~/.local/share/nmapui ~/.local/share/nmapui-elementary ~/.cache/nmapui-elementary
```

## Build from source

```bash
sudo apt install meson ninja-build valac pkg-config libgtk-4-dev libgranite-7-dev \
  libwebkitgtk-6.0-dev libsoup-3.0-dev libjson-glib-dev libwingpanel-9-dev
meson setup build --prefix="$HOME/.local"
meson compile -C build
meson install -C build
```

`-Dindicator=false` leaves out the Wingpanel module. Run the app from the build tree with
`build/io.github.techmore.NmapUI`. Environment variables:

| Variable | Default | Purpose |
|---|---|---|
| `NMAPUI_URL` | `http://127.0.0.1:9000` | Engine origin |
| `NMAPUI_SERVICE` | `nmapui.service` | systemd user unit the app starts and restarts |
| `NMAPUI_DEVTOOLS` | unset | Any value enables the WebKit inspector |
| `NMAPUI_SNAPSHOT` | unset | Write a PNG of the window after `NMAPUI_SNAPSHOT_DELAY` ms and quit |
| `NMAPUI_FORCE_DARK` | unset | `1`/`0` overrides the system color scheme (for renders) |

## Keyboard

| Shortcut | Action |
|---|---|
| Ctrl+1 … Ctrl+6 | Dashboard, History, Reports, Customers, Logs, Settings |
| Ctrl+R, F5 | Reload |
| Ctrl+Shift+O | Open in the default browser |
| Ctrl+Plus / Ctrl+Minus / Ctrl+0 | Zoom |
| Ctrl+Q | Quit |

## Verify

```bash
python3 -m pytest -q tests                      # summary helper
indicator/probe/run-probe.sh build/indicator out # indicator renders for four states (Xvfb)
scripts/snapshot.sh build out                    # window renders, light and dark (Xvfb)
desktop-file-validate build/data/io.github.techmore.NmapUI.desktop
appstreamcli validate --no-net build/data/io.github.techmore.NmapUI.metainfo.xml
```

CI runs the same steps in the `ghcr.io/elementary/docker:horus-unstable` container.

## How it fits with the other repositories

- **TM-NmapUI `main`** is the web product and the shared scanner engine (Flask, Socket.IO, reports).
  Its `static/css/elementary.css` theme is what this window shows; the native headerbar replaces the
  page's own header and tab strip.
- **TM-NmapUI `swift-native`** is the native macOS app.
- **tm-daedalus** packages the same engine as a frozen source bundle for managed scanners and talks
  to it through a loopback bridge. The elementary app and Daedalus can share one engine install on a
  machine only if they agree on the port; by default both use 9000.
