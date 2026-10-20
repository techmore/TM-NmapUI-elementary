#!/usr/bin/env bash
# Install (or update) the TM-NmapUI scanner engine for the current user and run it as a
# loopback-only systemd user service. Network Scanner (this repo) is only the front end.
#
#   scripts/install-backend.sh                 # clone/update into ~/.local/share/nmapui/app
#   NMAPUI_APP_DIR=~/Projects/TM-NmapUI scripts/install-backend.sh   # use an existing checkout
#   NMAPUI_REF=main scripts/install-backend.sh # pin a branch, tag or commit (default: main)
#
# Unprivileged scans use connect mode. For SYN/OS/ARP scans use the root service from
# TM-NmapUI's packaging/ubuntu/install-service.sh instead; this script never grants
# raw-socket capabilities.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_url=${NMAPUI_REPO:-https://github.com/techmore/TM-NmapUI.git}
ref=${NMAPUI_REF:-main}
app=${NMAPUI_APP_DIR:-$HOME/.local/share/nmapui/app}
unit_name=nmapui.service

# Where the service template lives: installed by meson, or the source tree when run from a checkout.
template=""
for candidate in "$here/../data/nmapui.service.in" \
                 "${XDG_DATA_HOME:-$HOME/.local/share}/io.github.techmore.NmapUI/nmapui.service.in" \
                 "/usr/share/io.github.techmore.NmapUI/nmapui.service.in" \
                 "/usr/local/share/io.github.techmore.NmapUI/nmapui.service.in"; do
  [[ -f "$candidate" ]] && { template=$candidate; break; }
done
[[ -n "$template" ]] || { echo "nmapui.service.in not found; build and install this project first." >&2; exit 1; }

echo "== 1/5 System packages"
packages=(nmap arp-scan xsltproc traceroute python3 python3-venv python3-dev build-essential git curl)
missing=()
for pkg in "${packages[@]}"; do dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg"); done
if ((${#missing[@]})); then
  echo "Installing: ${missing[*]}"
  sudo apt-get update -qq
  sudo apt-get install -y "${missing[@]}"
fi

echo "== 2/5 Scanner engine source ($ref)"
if [[ -d "$app/.git" ]]; then
  git -C "$app" fetch -q --tags origin
  git -C "$app" checkout -q --detach "origin/$ref" 2>/dev/null || git -C "$app" checkout -q --detach "$ref"
else
  mkdir -p "$(dirname "$app")"
  git clone -q "$repo_url" "$app"
  git -C "$app" checkout -q --detach "origin/$ref" 2>/dev/null || git -C "$app" checkout -q --detach "$ref"
fi
echo "engine at $(git -C "$app" rev-parse --short HEAD) in $app"

echo "== 3/5 Python environment"
if ! "$app/.venv/bin/python" -c "import flask, flask_socketio, gunicorn, playwright" 2>/dev/null; then
  rm -rf "$app/.venv"
  python3 -m venv "$app/.venv"
  "$app/.venv/bin/pip" install -q --upgrade pip
fi
"$app/.venv/bin/pip" install -q -r "$app/requirements.txt"
echo "venv ok: $("$app/.venv/bin/python" --version)"

echo "== 4/5 Chromium for PDF reports"
"$app/.venv/bin/python" -m playwright install chromium
sudo "$app/.venv/bin/python" -m playwright install-deps chromium >/dev/null 2>&1 \
  || echo "note: could not install Chromium system libraries; PDF export may fail"

echo "== 5/5 User service ($unit_name)"
unit="$HOME/.config/systemd/user/$unit_name"
mkdir -p "$(dirname "$unit")" "$HOME/.local/share/nmapui/logs"
sed "s|@APP_DIR@|$app|g" "$template" > "$unit"
# Retire earlier development units that bound the same port.
for old in nmapui-dev.service nmapui-local.service; do
  if systemctl --user cat "$old" >/dev/null 2>&1; then
    systemctl --user disable --now "$old" 2>/dev/null || true
    rm -f "$HOME/.config/systemd/user/$old"
  fi
done
systemctl --user daemon-reload
systemctl --user enable --now "$unit_name"
systemctl --user restart "$unit_name"
for _ in $(seq 1 30); do
  curl -fsS http://127.0.0.1:9000/api/health/live >/dev/null 2>&1 && break; sleep 1
done
if curl -fsS http://127.0.0.1:9000/api/health/live >/dev/null; then
  echo "scanner engine is up on 127.0.0.1:9000"
else
  echo "scanner engine did not answer; see: journalctl --user -u $unit_name -e" >&2
  exit 1
fi
