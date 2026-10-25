#!/usr/bin/env bash
# Stage an immutable shared-engine release, then atomically activate a managed user unit.
# NMAPUI_REF may override data/engine-revision with a reviewed full commit SHA; NMAPUI_APP_DIR may provide a local source checkout.
# --rollback restores the previous managed unit. No source checkout or scanner data is removed.
set -euo pipefail
[[ $(id -u) != 0 ]] || { echo 'Run this installer as your desktop user, without sudo.' >&2; exit 1; }
umask 077
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
base="$HOME/.local/share/nmapui"
unit="$HOME/.config/systemd/user/nmapui.service"
previous="$base/previous.service"
marker='# Managed by TM-NmapUI-elementary installer'
staging=''; candidate=''
trap '[[ -z "$staging" ]] || rm -rf "$staging"; [[ -z "$candidate" ]] || rm -f "$candidate"' EXIT
mkdir -p "$base" "$(dirname "$unit")"
# Refuse custom user units and system/root scanners before fetching or changing anything.
if [[ -e "$unit" ]] && ! grep -Fxq "$marker" "$unit"; then
  echo "Refusing to replace an unmanaged user unit: $unit" >&2; exit 1
fi
if systemctl is-active --quiet nmapui.service; then
  echo 'A system scanner service is active; keep that service and install with --no-backend.' >&2; exit 1
fi
enabled=0
systemctl --user is-enabled --quiet nmapui.service && enabled=1
active=0
systemctl --user is-active --quiet nmapui.service && active=1
if (( ! active )) && curl -sS --max-time 2 -o /dev/null http://127.0.0.1:9000/api/health/live 2>/dev/null; then
  echo 'Port 9000 already serves another process; refusing to replace it.' >&2; exit 1
fi
rollback=0
case ${1:-} in
  '') ;;
  --rollback) rollback=1 ;;
  *) echo 'Usage: install-backend.sh [--rollback]' >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || exit 2
if ((rollback)); then
  [[ -f "$previous" ]] && grep -Fxq "$marker" "$previous" || { echo 'No previous managed release.' >&2; exit 1; }
  candidate=$(mktemp "$base/unit.XXXXXX")
  cp "$previous" "$candidate"
else
  ref=${NMAPUI_REF:-$(cat "$here/../data/engine-revision")}
  if [[ ! $ref =~ ^[0-9a-fA-F]{40}$ ]]; then
    echo 'Set NMAPUI_REF to a reviewed full 40-character engine commit SHA.' >&2; exit 2
  fi
  ref=$(printf '%s' "$ref" | tr 'A-F' 'a-f')
  echo "== System packages"
  packages=(nmap arp-scan xsltproc traceroute python3 python3-venv python3-dev build-essential git curl)
  missing=()
  for pkg in "${packages[@]}"; do dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg"); done
  if ((${#missing[@]})); then
    sudo apt-get update -qq
    sudo apt-get install -y "${missing[@]}"
  fi
  release="$base/releases/$ref"
  mkdir -p "$base/releases"
  if [[ ! -f "$release/.nmapui-release.json" ]]; then
    [[ ! -e "$release" ]] || { echo "Unmanaged release directory: $release" >&2; exit 1; }
    staging=$(mktemp -d "$base/releases/.stage.XXXXXX")
    source=${NMAPUI_APP_DIR:-${NMAPUI_REPO:-https://github.com/techmore/TM-NmapUI.git}}
    git clone -q --no-hardlinks --no-checkout "$source" "$staging/app"
    git -C "$staging/app" checkout -q --detach "$ref"
    [[ $(git -C "$staging/app" rev-parse HEAD) == "$ref" ]]
    python3 -m venv "$staging/app/.venv"
    "$staging/app/.venv/bin/python" -m pip install -q -r "$staging/app/requirements.txt"
    "$staging/app/.venv/bin/python" -m playwright install chromium
    # Missing PDF libraries are an installation failure, never a success with broken exports.
    sudo "$staging/app/.venv/bin/python" -m playwright install-deps chromium
    python3 - "$staging/app/.nmapui-release.json" "$ref" "$source" <<'PY'
import json, sys
with open(sys.argv[1], 'w') as output:
    json.dump({'engine_commit': sys.argv[2], 'source': sys.argv[3]}, output, indent=2)
PY
    mv "$staging/app" "$release"
    rmdir "$staging"; staging=''
  fi
  [[ $(git -C "$release" rev-parse HEAD) == "$ref" ]] || exit 1
  git -C "$release" diff --quiet
  git -C "$release" diff --cached --quiet
  template="$here/../data/nmapui.service.in"
  [[ -f "$template" ]] || { echo "Missing service template: $template" >&2; exit 1; }
  candidate=$(mktemp "$base/unit.XXXXXX")
  python3 - "$template" "$release" "$candidate" <<'PY'
import pathlib, sys
path = sys.argv[2]
if any(ord(char) < 32 for char in path):
    raise SystemExit('Control characters are not supported in installation paths')
escaped = path.replace('\\', '\\\\').replace('"', '\\"').replace('%', '%%')
pathlib.Path(sys.argv[3]).write_text(pathlib.Path(sys.argv[1]).read_text().replace('@APP_DIR@', escaped))
PY
fi
backup=$(mktemp "$base/unit-backup.XXXXXX")
had_unit=0
if [[ -f "$unit" ]]; then cp "$unit" "$backup"; had_unit=1; fi
# Same filesystem: readers never see a partially written unit.
install -m 600 "$candidate" "$unit.new"
mv "$unit.new" "$unit"
rm -f "$candidate"
activated=0
if systemctl --user daemon-reload && systemctl --user enable nmapui.service && systemctl --user restart nmapui.service; then
  activated=1
fi
ready=0
for attempt in {1..30}; do
  ((activated)) || break
  if systemctl --user is-active --quiet nmapui.service && curl -fsS --max-time 2 http://127.0.0.1:9000/api/health/ready 2>/dev/null \
      | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("ready") is True else 1)' 2>/dev/null; then
    ready=1; break
  fi
  sleep 1
done
if ((ready)); then
  if ((had_unit)); then mv "$backup" "$previous"; else rm -f "$backup"; fi
  echo 'Scanner release ready on 127.0.0.1:9000; data and previous release preserved.'
else
  echo 'Candidate failed readiness; restoring the previous service configuration.' >&2
  systemctl --user stop nmapui.service || true
  if ((had_unit)); then mv "$backup" "$unit"; else rm -f "$unit" "$backup"; fi
  systemctl --user daemon-reload
  if ((enabled)); then systemctl --user enable nmapui.service; else systemctl --user disable nmapui.service || true; fi
  if ((active)); then systemctl --user restart nmapui.service; fi
  exit 1
fi
