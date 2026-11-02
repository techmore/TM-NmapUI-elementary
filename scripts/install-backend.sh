#!/usr/bin/env bash
# Install (or update) the TM-NmapUI scanner engine for the current user and run it as a
# loopback-only systemd user service. Network Scanner (this repo) is only the front end.
#
#   scripts/install-backend.sh                 # pinned engine into ~/.local/share/nmapui/app
#   NMAPUI_APP_DIR=~/Projects/TM-NmapUI scripts/install-backend.sh   # use an existing checkout
#   NMAPUI_REF=<full commit sha> scripts/install-backend.sh          # another reviewed engine commit
#
# The engine commit is pinned in data/engine-revision, so a reinstall deploys the engine this
# front end was tested with, not whatever is on TM-NmapUI's main branch that day.
# sudo is only used for apt-get with explicit package names: nothing from the engine checkout or
# its virtual environment (both writable by your account) ever runs as root.
#
# Unprivileged scans use connect mode. For SYN/OS/ARP scans use the root service from
# TM-NmapUI's packaging/ubuntu/install-service.sh instead; this script never grants
# raw-socket capabilities.
set -euo pipefail
[[ $(id -u) != 0 ]] || { echo "Run this installer as your desktop user, without sudo." >&2; exit 1; }
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_url=${NMAPUI_REPO:-https://github.com/techmore/TM-NmapUI.git}
app=${NMAPUI_APP_DIR:-$HOME/.local/share/nmapui/app}
unit_name=nmapui.service
unit="$HOME/.config/systemd/user/$unit_name"
engine=http://127.0.0.1:9000

# Data files: installed by meson, or the source tree when run from a checkout.
find_data() {
  local candidate
  for candidate in "$here/../data/$1" \
                   "${XDG_DATA_HOME:-$HOME/.local/share}/io.github.techmore.NmapUI/$1" \
                   "/usr/share/io.github.techmore.NmapUI/$1" \
                   "/usr/local/share/io.github.techmore.NmapUI/$1"; do
    [[ -f "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
}
template=$(find_data nmapui.service.in) || { echo "nmapui.service.in not found; build and install this project first." >&2; exit 1; }

if [[ -n ${NMAPUI_REF:-} ]]; then
  ref=$NMAPUI_REF
else
  revision=$(find_data engine-revision) || { echo "engine-revision not found; build and install this project first." >&2; exit 1; }
  ref=$(tr -d '[:space:]' < "$revision")
fi
if [[ ! $ref =~ ^[0-9a-fA-F]{40}$ ]]; then
  echo "NMAPUI_REF must be a full 40-character TM-NmapUI commit SHA, not a branch or tag (got '$ref')." >&2
  exit 2
fi
ref=$(printf '%s' "$ref" | tr 'A-F' 'a-f')

# Render the unit first, so an unusable path fails before anything is downloaded.
candidate=$(mktemp)
trap 'rm -f "$candidate"' EXIT
python3 -I "$here/render-unit.py" "$template" "$app" "$candidate"

# Don't start over a server this script doesn't manage: the app would show it as the scanner.
managed_active=0
for name in "$unit_name" nmapui-dev.service nmapui-local.service; do
  systemctl --user is-active --quiet "$name" 2>/dev/null && managed_active=1
done
if ((!managed_active)) && curl -s -o /dev/null --max-time 2 "$engine/" 2>/dev/null; then
  echo "Something else is already serving $engine; stop it, then run this again." >&2
  exit 1
fi

echo "== 1/5 System packages"
packages=(nmap arp-scan xsltproc traceroute python3 python3-venv python3-dev build-essential git curl)
missing=()
for pkg in "${packages[@]}"; do dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg"); done
if ((${#missing[@]})); then
  echo "Installing: ${missing[*]}"
  sudo apt-get update -qq
  sudo apt-get install -y "${missing[@]}"
fi

echo "== 2/5 Scanner engine source (${ref:0:12})"
if [[ -d "$app/.git" ]]; then
  git -C "$app" fetch -q --tags origin
else
  mkdir -p "$(dirname "$app")"
  git clone -q "$repo_url" "$app"
fi
git -C "$app" cat-file -e "$ref^{commit}" 2>/dev/null || git -C "$app" fetch -q origin "$ref"
git -C "$app" checkout -q --detach "$ref"
if [[ $(git -C "$app" rev-parse HEAD) != "$ref" ]]; then
  echo "Could not check out engine commit $ref in $app." >&2
  exit 1
fi
echo "engine at ${ref:0:12} in $app"

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
# Ask Playwright (as you, dry run) which system libraries Chromium needs, then install exactly
# those names with apt-get.
if deps=$("$app/.venv/bin/python" -m playwright install-deps --dry-run chromium 2>/dev/null \
          | python3 -I "$here/playwright-deps.py"); then
  read -r -a deps <<< "$deps"
  need=()
  for pkg in "${deps[@]}"; do dpkg -s "$pkg" >/dev/null 2>&1 || need+=("$pkg"); done
  if ((${#need[@]})); then
    echo "Installing Chromium libraries: ${need[*]}"
    { sudo apt-get update -qq && sudo apt-get install -y --no-install-recommends "${need[@]}"; } \
      || echo "note: could not install Chromium system libraries; PDF export may fail"
  fi
else
  echo "note: could not list Chromium's system libraries; PDF export may fail"
fi

echo "== 5/5 User service ($unit_name)"
mkdir -p "$(dirname "$unit")" "$HOME/.local/share/nmapui/logs"
install -m 600 "$candidate" "$unit.new"
mv "$unit.new" "$unit"
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
ready() {
  curl -fsS --max-time 2 "$engine/api/health/ready" 2>/dev/null \
    | python3 -I -c 'import json, sys; sys.exit(0 if json.load(sys.stdin).get("ready") is True else 1)' 2>/dev/null
}
for _ in $(seq 1 30); do
  ready && break; sleep 1
done
if ready; then
  echo "scanner engine ${ref:0:12} is ready on $engine"
else
  echo "scanner engine did not become ready; see: journalctl --user -u $unit_name -e" >&2
  exit 1
fi
